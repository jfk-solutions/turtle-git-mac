// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

/// Exercises Commit's real owned initial gate and Git Settings handoff using
/// private repositories/preferences. Every window stays invisible/offscreen.
@MainActor enum CommitIdentityVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String)throws {if !condition{throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Commit identity timeout at \(line)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func capture(_ window:NSWindow,name:String)async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_COMMIT_IDENTITY_CAPTURE_DIR"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned identity capture unavailable")}
        let directory=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let alpha=window.alphaValue,appearance=window.appearance
        window.alphaValue=1;window.setFrameOrigin(.init(x:-12000,y:-12000));window.orderFront(nil)
        defer{window.alphaValue=alpha;window.appearance=appearance}
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let item=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned identity window unavailable")}
            let options=SCStreamConfiguration();options.width=Int(window.frame.width*2);options.height=Int(window.frame.height*2);options.showsCursor=false;options.ignoreShadowsSingleWindow=true;options.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:item),configuration:options)
            guard let bytes=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw Failure(description:"Identity capture cannot encode PNG")}
            try bytes.write(to:directory.appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    struct Witness:Equatable {let head:Data,index:Data,tracked:Data,template:Data}
    static func witness(_ repo:GitRepository)async throws->Witness {
        .init(head:try await repo.run(["rev-parse","HEAD"]).stdout,index:try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),
              tracked:try Data(contentsOf:repo.root.appendingPathComponent("tracked.txt")),template:try Data(contentsOf:repo.root.appendingPathComponent("template.txt")))
    }
    static func fixture(_ root:URL,git:URL,name:String)async throws->GitRepository {
        let directory=root.appendingPathComponent(name,isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let repo=GitRepository(root:directory,executable:git,askpass:nil)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Private identity QA"),("user.email","identity@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","false")] {_=try await repo.run(["config",key,value])}
        try Data("original tracked bytes\n".utf8).write(to:directory.appendingPathComponent("tracked.txt"));try await repo.stage(["tracked.txt"]);_=try await repo.commit(message:"Initial identity fixture")
        try Data("working tracked bytes\n".utf8).write(to:directory.appendingPathComponent("tracked.txt"))
        try Data("Template waits for identity\n".utf8).write(to:directory.appendingPathComponent("template.txt"));_=try await repo.run(["config","commit.template",directory.appendingPathComponent("template.txt").path])
        // Empty local entries deterministically mask real global identity without
        // changing any user preference or Git configuration outside this repo.
        for key in ["user.name","user.email"] {_=try await repo.run(["config",key,""])}
        return repo
    }
    static func repair(_ repo:GitRepository)async throws {
        _=try await repo.run(["config","user.name","Repaired identity"]);_=try await repo.run(["config","user.email","repaired@example.invalid"])
    }
    static func footer(_ title:String,_ navigation:SettingsNavigationController)throws->NSButton {
        guard let button=views(navigation.view).compactMap({$0 as? NSButton}).first(where:{$0.title==title && $0.target === navigation}),button.action != nil else{throw Failure(description:"Owned Settings footer missing: "+title)};return button
    }
    static func click(_ button:NSButton){guard let action=button.action else{return};_=NSApp.sendAction(action,to:button.target,from:button)}
    /// SwiftUI can publish the accessibility caption on a wrapper rather than
    /// its native NSTextField. Prefer the caption, then use the real User Info
    /// fields' visual order (Name, Email, Signing key) within this known page.
    static func identityFields(_ navigation:SettingsNavigationController)->[NSTextField] {
        let fields=views(navigation.view).compactMap{$0 as? NSTextField}.filter{$0.isEditable}
        if let name=fields.first(where:{$0.accessibilityLabel()=="Name:"}),let email=fields.first(where:{$0.accessibilityLabel()=="Email:"}) {return [name,email]}
        guard fields.count>=2 && fields.count<=3 else{return []}
        return Array(fields.sorted{$0.convert($0.bounds,to:nil).midY > $1.convert($1.bounds,to:nil).midY}.prefix(2))
    }
    static func settingsDiagnostic(_ navigation:SettingsNavigationController)->String {
        let buttons=views(navigation.view).compactMap{$0 as? NSButton}.filter{["Effective","Local","Global","System"].contains($0.title)}.map{"\($0.title):enabled=\($0.isEnabled),state=\($0.state.rawValue)"}
        let fields=views(navigation.view).compactMap{$0 as? NSTextField}.map{"label=\($0.accessibilityLabel() ?? "nil"),enabled=\($0.isEnabled),editable=\($0.isEditable),y=\($0.convert($0.bounds,to:nil).midY),value=\($0.stringValue.debugDescription)"}
        return "page=\(navigation.selected.rawValue),reads=\(GitConfigurationSettingsModel.activeReads),radios=[\(buttons.joined(separator:"; "))],fields=[\(fields.joined(separator:"; "))]"
    }
    static func configurationBytes(_ path:String?)throws->Data? {
        guard let path,FileManager.default.fileExists(atPath:path) else{return nil}
        return try Data(contentsOf:URL(fileURLWithPath:path))
    }
    static func identity(_ name:String="Effective author",email:String="effective@example.invalid")->ReplayUserIdentity {
        .init(authorName:name,authorEmail:email,committerName:name,committerEmail:email)
    }
    static func emptyIdentity()->ReplayUserIdentity {identity("",email:"")}
    static func verify()async throws {
        let parent=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),root=parent.appendingPathComponent("commit-identity-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let suite="TurtleGit.CommitIdentity."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"HintHierarchicalConfig");prefs.set(true,forKey:"HintStagingMode");prefs.set(true,forKey:"Commit.SkipCancelConfirmation");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"AddBeforeCommit")
        let originalStandardAppearance=UserDefaults.standard.data(forKey:"TurtleGit.UnifiedDiffAppearance")
        let globalConfiguration=ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]
        let originalGlobalConfiguration=try configurationBytes(globalConfiguration)
        var privateAppearance=UnifiedDiffAppearance();privateAppearance.fontSize=29;privateAppearance.save(to:prefs)
        var owners:[CommitWindowController]=[],releases:[()->Void]=[]
        func drained()->Bool {
            CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && SettingsSheetController.activeSheets==0 && GitConfigurationSettingsModel.activeReads==0 && GitConfigurationSettingsModel.activeSaves==0 && GitConfigurationSettingsModel.activeSheetReleases==0 && SettingsTransaction.activeApplications==0 && SettingsTransaction.activeRetirements==0 && ClientHookSession.activeOperations==0 && ClientHookProcessPool.shared.activeScripts==0
        }
        func cleanup()async {
            releases.forEach{$0()};releases=[]
            owners.forEach{$0.close()}
            for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            owners.forEach{$0.window?.orderOut(nil)}
        }
        func owner(_ repo:GitRepository)->CommitWindowController {
            let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs);owners.append(owner)
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000));owner.window?.orderFront(nil)
            return owner
        }
        func prompt(_ owner:CommitWindowController)async throws->NSAlert {
            try await wait{owner.identityQuestion != nil}
            guard let question=owner.identityQuestion else{throw Failure(description:"Identity question disappeared")}
            question.window.alphaValue=0;question.window.setFrameOrigin(.init(x:-12000,y:-12000));return question
        }
        func ready(_ model:CommitWindowModel)async throws {try await wait{!model.busy && !model.preparingCommitIdentity && model.commitIdentityPrepared && model.changelistsLoaded && model.error==nil}}
        do {
            let repo=try await fixture(root,git:git,name:"native-settings"),before=try await witness(repo),controller=owner(repo),model=controller.model
            var statuses=0,hookReads=0
            model.readCommitIdentity={token in try await repo.replayUserIdentity(environment:[:],cancellation:token)}
            model.queryCommitStatus={parent,token in statuses += 1;return try await repo.commitDialogStatus(amendToParent:parent,cancellation:token)}
            let hook=repo.root.appendingPathComponent(".git/identity-start.sh"),log=repo.root.appendingPathComponent(".git/identity-start.log")
            let script="""
            #!/bin/sh
            set -eu
            test -n "$(/usr/bin/git -C "$3" config user.name)"
            test -n "$(/usr/bin/git -C "$3" config user.email)"
            printf '%s\\n' start >> "$3/.git/identity-start.log"
            /bin/cat "$2" >> "$3/.git/identity-start.log"
            """
            try script.write(to:hook,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:hook.path)
            let command="/bin/sh '"+hook.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
            model.clientHooks.readProjectHooks={_,_ in hookReads += 1;return [.init(type:.startCommit,path:repo.root.path,command:command,wait:true,show:false,local:false)]}
            guard let invocation=try PrimaryCommandInvocation.parse(arguments:["/command:commit","/path:"+repo.root.appendingPathComponent("tracked.txt").path,"/bugid:731","/logmsg:Command preset message"],currentDirectory:repo.root.path) else{throw Failure(description:"Commit preset failed to parse")}
            model.applyCommandLine(invocation,message:"Command preset message")
            model.setAuthor=true;model.author="Explicit author <explicit@example.invalid>";model.setAuthorDate=true
            let authorDate=Date(timeIntervalSince1970:1_700_000_000);model.authorDate=authorDate
            model.reload(paths:["tracked.txt"])
            let question=try await prompt(controller)
            try require(question.buttons.map(\.title)==["Yes","No"] && model.preparingCommitIdentity && !model.canCommit && model.entries.isEmpty && statuses==0 && hookReads==0 && !FileManager.default.fileExists(atPath:log.path),"Missing identity entered status/template/start-hook work or omitted source Yes/No")
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Identity gate lost Quit ownership")
            try await capture(question.window,name:"commit-missing-identity")
            question.buttons[0].performClick(nil)
            try await wait{controller.identitySettingsWindow?.sheetParent===controller.window && controller.identityNavigation != nil}
            let settings=controller.identitySettingsWindow!,navigation=controller.identityNavigation!
            settings.setFrameOrigin(.init(x:-12000,y:-12000))
            try require(settings.alphaValue==0 && navigation.selected == .git && model.inputsBlocked && !controller.commandsAvailable && SettingsSheetController.activeSheets==1,"Identity repair did not own the captured Git Settings child")
            try await wait{navigation.canDismiss && GitConfigurationSettingsModel.activeReads==0}
            try await capture(settings,name:"commit-identity-settings")
            navigation.requestCommandPage(.unifiedDiff)
            try await wait{navigation.selected == .unifiedDiff && views(navigation.view).compactMap({$0 as? NSTextField}).contains(where:{$0.stringValue=="29"})}
            navigation.requestCommandPage(.git)
            try await wait{navigation.selected == .git && navigation.canDismiss && GitConfigurationSettingsModel.activeReads==0}
            // Cancel does not count as configuring identity. Commit must perform
            // another authoritative read and remain before the status/hook fence.
            click(try footer("Cancel",navigation));_=try await prompt(controller)
            try require(statuses==0 && hookReads==0 && model.message=="Command preset message" && model.issueID=="731","Settings Cancel continued Commit or dropped command presets")
            controller.identityQuestion!.buttons[0].performClick(nil)
            try await wait{controller.identitySettingsWindow != nil && controller.identityNavigation?.canDismiss==true && GitConfigurationSettingsModel.activeReads==0}
            let repairNavigation=controller.identityNavigation!,repairWindow=controller.identitySettingsWindow!
            // The Settings host can be attached before SwiftUI's first page
            // activation/read settles. Invoke the live, enabled native radio.
            do {
                try await wait{GitConfigurationSettingsModel.activeReads==0 && views(repairNavigation.view).compactMap({$0 as? NSButton}).contains(where:{$0.title=="Local" && $0.isEnabled})}
                guard let local=views(repairNavigation.view).compactMap({$0 as? NSButton}).first(where:{$0.title=="Local" && $0.isEnabled}) else{throw Failure(description:"Actual Git Settings Local radio absent")}
                local.performClick(nil)
                try await wait{
                    let liveLocal=views(repairNavigation.view).compactMap({$0 as? NSButton}).first(where:{$0.title=="Local"})
                    let fields=identityFields(repairNavigation)
                    return GitConfigurationSettingsModel.activeReads==0 && liveLocal?.state == .on && fields.count==2 && fields.allSatisfy{$0.isEnabled && $0.isEditable}
                }
            }catch{throw Failure(description:"Native Git Settings did not settle: \(error); \(settingsDiagnostic(repairNavigation))")}
            let fields=identityFields(repairNavigation)
            for (field,value) in zip(fields,["Repaired identity","repaired@example.invalid"]) {
                field.stringValue=value;field.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:field))
            }
            // The production Local-source action also selects Local as the
            // save destination. SwiftUI's Picker need not be an NSPopUpButton;
            // verify the actual source choice and resulting local/global bytes.
            try require(views(repairNavigation.view).compactMap({$0 as? NSButton}).contains(where:{$0.title=="Local" && $0.state == .on}),"Native Local source choice was lost before Apply")
            repairWindow.makeFirstResponder(nil);click(try footer("OK",repairNavigation));try await ready(model)
            try await wait{controller.identitySettingsWindow==nil && controller.window?.attachedSheet==nil && ClientHookProcessPool.shared.activeScripts==0}
            let stored=try await repo.gitConfiguration(source:.local)
            try require(stored.name.value=="Repaired identity" && stored.email.value=="repaired@example.invalid","Actual Git Settings transaction did not save the private local identity")
            try require(try configurationBytes(globalConfiguration)==originalGlobalConfiguration,"Local Git Settings repair changed the global configuration")
            try require(statuses==1 && hookReads==1 && (try String(contentsOf:log,encoding:.utf8)).contains("Command preset message"),"Repaired identity did not release exactly one original status/StartHook transaction")
            let presetChecks:[(String,Bool,String)]=[
                ("message",model.message=="Command preset message",model.message.debugDescription),
                ("issue ID",model.issueID=="731",model.issueID.debugDescription),
                ("scope",model.scopePaths==["tracked.txt"],String(describing:model.scopePaths)),
                ("author enabled",model.setAuthor,String(model.setAuthor)),
                ("author",model.author=="Explicit author <explicit@example.invalid>",model.author.debugDescription),
                ("author date enabled",model.setAuthorDate,String(model.setAuthorDate)),
                ("author date",model.authorDate==authorDate,"actual=\(model.authorDate.timeIntervalSince1970), expected=\(authorDate.timeIntervalSince1970)")]
            let presetDiagnostic=presetChecks.map{"\($0.0): \($0.2)"}.joined(separator:"; ")
            for (name,matches,_) in presetChecks {try require(matches,"Identity/settings handoff changed preset "+name+"; "+presetDiagnostic)}
            try require(try await witness(repo)==before,"Identity repair or initialization changed HEAD/index/source/template bytes")
            controller.close();try await wait{drained()}
            // No aborts the initial command before status, templates or hooks.
            let noRepo=try await fixture(root,git:git,name:"declined"),noBefore=try await witness(noRepo),declined=owner(noRepo)
            var noReads=0,noClosed=0
            declined.onClosed={noClosed += 1};declined.model.readCommitIdentity={_ in emptyIdentity()}
            declined.model.queryCommitStatus={_,_ in noReads += 1;return []}
            declined.model.reload();let noQuestion=try await prompt(declined);noQuestion.buttons[1].performClick(nil)
            try await wait{noClosed==1 && !declined.model.preparingCommitIdentity && CommitWindowModel.activeReloads==0}
            try require(noReads==0 && !declined.model.commitIdentityPrepared && declined.identitySettingsWindow==nil && declined.model.message.isEmpty,"No did not abort before Commit initialization")
            try require(try await witness(noRepo)==noBefore,"Declining identity changed repository content")
            // Read errors remain retryable. Neither failure nor retry overwrites
            // a draft, and a complete captured identity seeds an empty author.
            let retryRepo=try await fixture(root,git:git,name:"retry"),retry=owner(retryRepo)
            var attempts=0,retryStatuses=0
            retry.model.readCommitIdentity={_ in attempts += 1;if attempts==1 {throw Failure(description:"Injected initial identity read failure")};return identity("Captured author",email:"captured@example.invalid")}
            retry.model.queryCommitStatus={parent,token in retryStatuses += 1;return try await retryRepo.commitDialogStatus(amendToParent:parent,cancellation:token)}
            retry.model.reload();try await wait{!retry.model.busy && retry.model.error != nil && !retry.model.preparingCommitIdentity}
            try require(retryStatuses==0 && !retry.model.commitIdentityPrepared && retry.model.inputsBlocked && retry.model.canRefresh && retry.refreshCommandAvailable,"Failed identity read entered status, enabled form actions or lost Refresh retry")
            retry.model.reload();try await ready(retry.model)
            try require(attempts==2 && retryStatuses==1 && retry.model.author=="Captured author <captured@example.invalid>" && retry.model.message.contains("Template waits for identity"),"Retry did not initialize from the captured effective author/template")
            retry.close();try await wait{drained()}
            // A retired model retains the actual ignored-cancellation read until
            // its continuation returns. No late identity or status may publish.
            let heldRepo=try await fixture(root,git:git,name:"held-read"),held=owner(heldRepo)
            var readReply:CheckedContinuation<ReplayUserIdentity,Error>?,readToken:OperationCancellation?,lateStatuses=0,closedReads=0
            releases.append{readReply?.resume(returning:identity());readReply=nil}
            held.onClosed={closedReads += 1};held.model.message="Keep retired draft"
            held.model.readCommitIdentity={token in readToken=token;return try await withCheckedThrowingContinuation{readReply=$0}}
            held.model.queryCommitStatus={_,_ in lateStatuses += 1;return []}
            held.model.reload();try await wait{readReply != nil}
            try require(held.model.inputsBlocked && !held.model.canCommit && CommitWindowModel.activeReloads>0,"Held identity read lost input/worker ownership")
            held.close();try require(readToken?.isCancelled==true && CommitWindowModel.activeReloads>0 && closedReads==0,"Forced close released an undrained identity read")
            readReply?.resume(returning:identity("Late author"));readReply=nil
            try await wait{closedReads==1 && CommitWindowModel.activeReloads==0}
            try require(lateStatuses==0 && !held.model.commitIdentityPrepared && held.model.message=="Keep retired draft" && held.model.author.isEmpty && held.identityQuestion==nil,"Late identity result recreated/published into a retired Commit")
            // Settings is itself an owned asynchronous phase. An ignored late
            // repair callback cannot authorize a retired window's reload.
            let repairRepo=try await fixture(root,git:git,name:"held-repair"),lateRepair=owner(repairRepo)
            var repairReply:CheckedContinuation<Bool,Never>?,repairToken:OperationCancellation?,repairReads=0,repairStatuses=0,closedRepairs=0
            releases.append{repairReply?.resume(returning:true);repairReply=nil}
            lateRepair.onClosed={closedRepairs += 1}
            lateRepair.model.readCommitIdentity={_ in repairReads += 1;return emptyIdentity()}
            lateRepair.model.repairCommitIdentity={token in repairToken=token;return await withCheckedContinuation{repairReply=$0}}
            lateRepair.model.queryCommitStatus={_,_ in repairStatuses += 1;return []}
            lateRepair.model.reload();try await wait{repairReply != nil}
            lateRepair.close();try require(repairToken?.isCancelled==true && closedRepairs==0 && CommitWindowModel.activeReloads>0,"Closing held Settings callback released Commit before drain")
            repairReply?.resume(returning:true);repairReply=nil;try await wait{closedRepairs==1 && CommitWindowModel.activeReloads==0}
            try require(repairReads==1 && repairStatuses==0 && !lateRepair.model.commitIdentityPrepared && lateRepair.identitySettingsWindow==nil,"Late Settings response started another identity read or status")
            // Exercise forced retirement of an actual hidden Settings child too.
            let settingsRepo=try await fixture(root,git:git,name:"retired-settings"),retired=owner(settingsRepo)
            var retiredClosed=0,retiredStatus=0
            retired.onClosed={retiredClosed += 1};retired.model.readCommitIdentity={_ in emptyIdentity()}
            retired.model.queryCommitStatus={_,_ in retiredStatus += 1;return []}
            retired.model.reload();let retiredQuestion=try await prompt(retired);retiredQuestion.buttons[0].performClick(nil)
            try await wait{retired.identitySettingsWindow?.sheetParent===retired.window && retired.identityNavigation?.canDismiss==true}
            let retiredChild=retired.identitySettingsWindow!
            try require(retiredChild.alphaValue==0 && retired.model.hasCommitIdentitySettings,"Actual Settings child escaped invisible Commit ownership")
            retired.close();try await wait{retiredClosed==1 && retired.identitySettingsWindow==nil && retired.window?.attachedSheet==nil && drained()}
            try require(retiredStatus==0 && retired.identityQuestion==nil && retiredChild.sheetParent==nil && !retiredChild.isVisible,"Forced close left Settings attached or continued initialization")
            // The gate's all-four-field contract rejects an absent committer
            // even when author fields are supplied by an environment override.
            let missingCommitterRepo=try await fixture(root,git:git,name:"missing-committer"),missingCommitter=owner(missingCommitterRepo)
            var committerStatuses=0
            missingCommitter.model.readCommitIdentity={_ in .init(authorName:"Override",authorEmail:"override@example.invalid",committerName:"",committerEmail:"")}
            missingCommitter.model.queryCommitStatus={_,_ in committerStatuses += 1;return []}
            missingCommitter.model.reload();let committerQuestion=try await prompt(missingCommitter)
            try require(committerStatuses==0 && !missingCommitter.model.commitIdentityPrepared,"Author override bypassed missing committer identity")
            committerQuestion.buttons[1].performClick(nil);try await wait{drained()}
            try require(UserDefaults.standard.data(forKey:"TurtleGit.UnifiedDiffAppearance")==originalStandardAppearance,"Captured Commit Settings changed standard preferences")
            try await cleanup();try require(drained(),"Identity fixture leaked workers or Settings children")
            prefs.removePersistentDomain(forName:suite);try FileManager.default.removeItem(at:root)
            print("PASS Commit identity: initial source gate, native Yes/No and real Git Settings Apply, retry, template/status/StartHook ordering, captured presets, effective author seed and late-read/settings retirement")
        }catch{
            await cleanup();prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root);throw error
        }
    }
}
