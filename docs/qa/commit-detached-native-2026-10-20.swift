// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

/// Actual Commit warning/Branch child and cancelled-history transitions. All
/// repositories, preferences and invisible/offscreen windows belong to this run.
@MainActor enum CommitDetachedVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {if !condition {throw Failure(description:"\(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Commit safety timeout at \(line)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func pressDefault(_ window:NSWindow) {
        window.makeFirstResponder(nil)
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        if !window.performKeyEquivalent(with:event) {window.sendEvent(event)}
    }
    static func waitForBranchName(_ child:BranchTagWindowController,name:String)async throws {
        child.window?.contentView?.layoutSubtreeIfNeeded()
        // A SwiftUI Button may expose its caption through an accessibility
        // wrapper rather than NSButton.title. Drive its real default keyboard
        // action after the editable native name field reflects the new draft.
        await Task.yield()
        try await wait{
            guard child.model.canEditForm,child.model.options.name==name else{return false}
            let fields=views(child.window?.contentView).compactMap{$0 as? NSTextField}.filter{$0.isEditable}
            return fields.isEmpty || fields.contains(where:{$0.stringValue==name})
        }
    }
    static func capture(_ window:NSWindow,name:String)async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_COMMIT_SAFETY_CAPTURE_DIR"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned safety capture unavailable")}
        let directory=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let alpha=window.alphaValue,appearance=window.appearance
        window.alphaValue=1;window.setFrameOrigin(.init(x:-12000,y:-12000));window.orderFront(nil)
        defer{window.alphaValue=alpha;window.appearance=appearance}
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let item=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned safety window unavailable")}
            let options=SCStreamConfiguration();options.width=Int(window.frame.width*2);options.height=Int(window.frame.height*2);options.showsCursor=false;options.ignoreShadowsSingleWindow=true;options.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:item),configuration:options)
            guard let bytes=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw Failure(description:"Safety capture cannot encode PNG")}
            try bytes.write(to:directory.appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    struct Witness:Equatable {let head:Data,index:Data,work:Data,configuration:Data}
    static func witness(_ repo:GitRepository)async throws->Witness {
        .init(head:try await repo.run(["rev-parse","HEAD"]).stdout,index:try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),work:try Data(contentsOf:repo.root.appendingPathComponent("tracked.txt")),configuration:try Data(contentsOf:repo.root.appendingPathComponent(".git/config")))
    }
    static func fixture(_ parent:URL,git:URL,name:String,detach:Bool = true)async throws->GitRepository {
        let directory=parent.appendingPathComponent(name,isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let repo=GitRepository(root:directory,executable:git,askpass:nil)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Private safety QA"),("user.email","safety@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","false")] {_=try await repo.run(["config",key,value])}
        try Data("original\n".utf8).write(to:directory.appendingPathComponent("tracked.txt"));try await repo.stage(["tracked.txt"]);_=try await repo.commit(message:"Baseline safety fixture")
        if detach {_=try await repo.run(["checkout","--detach","HEAD"])}
        try Data("working changes\n".utf8).write(to:directory.appendingPathComponent("tracked.txt"))
        return repo
    }
    static func preferences(_ suite:String)->UserDefaults {
        let prefs=UserDefaults(suiteName:suite)!
        for key in ["HintHierarchicalConfig","HintStagingMode","Commit.SkipCancelConfirmation"] {prefs.set(true,forKey:key)}
        for key in ["EnableGravatar","AddBeforeCommit","NewBranchSwitchTo","ConfirmKillProcess"] {prefs.set(false,forKey:key)}
        return prefs
    }
    static func ready(_ model:CommitWindowModel)async throws {try await wait{!model.busy && model.commitIdentityPrepared && model.changelistsLoaded && !model.loadingAuthorIdentity && !model.loadingAuthorDate && model.error==nil}}
    static func prepare(_ owner:CommitWindowController,message:String = "Safety commit")async throws {
        owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000));owner.window?.orderFront(nil)
        let model=owner.model;model.reload(paths:["."]);try await ready(model)
        model.message=message;model.checked=["tracked.txt"]
        // Keep the real Git commit/progress model, while avoiding an unrelated
        // progress window or post-action prompt in this family check.
        model.onCommitProgress={$0.dismissWithoutWindow=true}
        try await wait{model.canCommit}
    }
    static func drained()->Bool {CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && BranchTagWindowModel.activeReads==0 && BranchTagWindowModel.activeCreations==0 && BranchTagWindowController.activeReleases==0 && ClientHookSession.activeOperations==0}
    static func detached()async throws {
        let parent=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),suite="TurtleGit.CommitDetached."+UUID().uuidString,prefs=preferences(suite)
        var owners:[CommitWindowController]=[],unblock:[()->Void]=[]
        func owner(_ repo:GitRepository)->CommitWindowController {let value=CommitWindowController(repository:repo,access:nil,defaults:prefs);owners.append(value);return value}
        func cleanup()async {unblock.forEach{$0()};unblock=[];owners.forEach{$0.close()};for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};owners.forEach{$0.window?.orderOut(nil)}}
        do {
            // Cancel then No on the same captured request. Native controls must
            // preserve all draft/index bytes on the cancelled warning.
            let repo=try await fixture(parent,git:git,name:"cancel-no"),controller=owner(repo),model=controller.model
            try await prepare(controller);let before=try await witness(repo)
            model.issueID="731";model.setAuthor=true;model.author="Captured author <captured@example.invalid>"
            let date=Date(timeIntervalSince1970:1_700_000_000);model.setAuthorDate=true;model.authorDate=date
            // Let intentional author/date edits settle before taking the draft.
            try await Task.sleep(nanoseconds:200_000_000)
            try await wait{!model.loadingAuthorIdentity && !model.loadingAuthorDate}
            model.author="Captured author <captured@example.invalid>";model.authorDate=date
            model.commit();try await wait{controller.detachedQuestion != nil}
            let question=controller.detachedQuestion!
            try require(question.buttons.map(\.title)==["Yes","No","Cancel"] && model.busy && model.preparingDetachedHead && model.commitProgress==nil,"Source warning buttons or preflight fence missing")
            try require(question.window.alphaValue==0 && question.window.sheetParent===controller.window && !controller.commandsAvailable,"Warning escaped invisible owner")
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Warning lost Quit accounting")
            try await capture(question.window,name:"commit-detached-warning")
            question.buttons[2].performClick(nil);try await wait{!model.busy && controller.detachedQuestion==nil}
            let afterCancel=try await witness(repo)
            try require(afterCancel==before,"Cancelled warning mutated HEAD/index/source/config")
            try require(model.message=="Safety commit" && model.issueID=="731" && model.checked.contains("tracked.txt") && model.setAuthor && model.author=="Captured author <captured@example.invalid>" && model.setAuthorDate && model.authorDate==date,"Cancelled warning lost captured draft/presets")
            model.commit();try await wait{controller.detachedQuestion != nil};controller.detachedQuestion!.buttons[1].performClick(nil)
            try await wait{!model.busy && CommitWindowModel.activeCommitPreflights==0}
            let committed=try await repo.run(["show","HEAD:tracked.txt"]).stdout,branch=try await repo.branch(),subject=try await repo.run(["show","-s","--format=%s","HEAD"]).text
            try require(branch.isEmpty && committed==Data("working changes\n".utf8) && subject=="Safety commit\n","No did not commit once while detached")

            // Yes opens the complete existing Create Branch UI. Exercise its
            // real Create button, rather than replacing branch mutation with a mock.
            let branchRepo=try await fixture(parent,git:git,name:"yes-branch"),branchOwner=owner(branchRepo),branchModel=branchOwner.model
            try await prepare(branchOwner,message:"Created branch commit")
            branchModel.commit();try await wait{branchOwner.detachedQuestion != nil};branchOwner.detachedQuestion!.buttons[0].performClick(nil)
            try await wait{branchOwner.detachedBranch != nil}
            let child=branchOwner.detachedBranch!
            try await wait{child.model.canEditForm && !child.model.busy && !child.model.chooser.busy}
            try require(!child.model.isTag && child.model.useHead && child.model.switchAfterCreation && child.model.presentationPreferences === prefs && child.window?.sheetParent===branchOwner.window && child.window?.alphaValue==0,"Owned Create Branch lost source switch default/context/preferences")
            try await capture(child.window!,name:"commit-detached-create-branch")
            child.model.options.name="--invalid"
            try await waitForBranchName(child,name:"--invalid")
            let beforeInvalid=try await witness(branchRepo)
            pressDefault(child.window!)
            try await wait{child.questionWindow != nil && !child.model.busy}
            let afterInvalid=try await witness(branchRepo)
            try require(afterInvalid==beforeInvalid && branchModel.preparingDetachedHead && branchModel.commitProgress==nil,"Invalid branch attempt escaped into Commit or mutated repository")
            guard let acknowledge=views(child.questionWindow?.contentView).compactMap({$0 as? NSButton}).first(where:{$0.title=="OK"}) else{throw Failure(description:"Actual branch failure acknowledgement missing")}
            acknowledge.performClick(nil);try await wait{child.questionWindow==nil && child.model.canEditForm}
            child.model.options.name="safety/topic"
            try await waitForBranchName(child,name:"safety/topic")
            pressDefault(child.window!)
            try await wait{!branchModel.busy && branchOwner.detachedBranch==nil && CommitWindowModel.activeCommitPreflights==0}
            let createdBranch=try await branchRepo.branch(),createdBytes=try await branchRepo.run(["show","HEAD:tracked.txt"]).stdout
            try require(createdBranch=="safety/topic" && createdBytes==Data("working changes\n".utf8),"Yes/Create did not switch and continue the captured Commit")

            // Cancelling Branch abandons the current Commit attempt; a later
            // Commit can reoffer the warning with the same original draft.
            let cancelRepo=try await fixture(parent,git:git,name:"branch-cancel"),cancelOwner=owner(cancelRepo),cancelModel=cancelOwner.model
            try await prepare(cancelOwner,message:"Retained after branch cancel");let cancelBefore=try await witness(cancelRepo)
            cancelModel.commit();try await wait{cancelOwner.detachedQuestion != nil};cancelOwner.detachedQuestion!.buttons[0].performClick(nil)
            try await wait{cancelOwner.detachedBranch?.model.canCancel==true && cancelOwner.detachedBranch?.model.busy==false && cancelOwner.detachedBranch?.model.chooser.busy==false}
            let quitChild=cancelOwner.detachedBranch!
            cancelOwner.setQuitConfirmation(true)
            try require(quitChild.model.confirmingQuit && !quitChild.model.canEditForm && !quitChild.model.canCancel,"Quit confirmation did not freeze the owned Branch child")
            quitChild.model.options.name="blocked-during-quit";quitChild.model.create()
            cancelOwner.setQuitConfirmation(false)
            try await wait{quitChild.model.canCancel && quitChild.model.canEditForm}
            cancelOwner.detachedBranch!.model.cancel();try await wait{!cancelModel.busy && cancelOwner.detachedBranch==nil}
            let afterBranchCancel=try await witness(cancelRepo)
            try require(afterBranchCancel==cancelBefore && cancelModel.message=="Retained after branch cancel","Branch Cancel mutated repository or draft")
            cancelModel.commit();try await wait{cancelOwner.detachedQuestion != nil};cancelOwner.detachedQuestion!.buttons[2].performClick(nil);try await wait{!cancelModel.busy}



            // The user can uncheck Switch in the complete branch dialog. A
            // successful ref creation alone must not count as attached HEAD:
            // authoritative re-read must offer the warning again.
            let unswitchedRepo=try await fixture(parent,git:git,name:"unswitched-branch"),unswitchedOwner=owner(unswitchedRepo),unswitchedModel=unswitchedOwner.model
            try await prepare(unswitchedOwner,message:"Unswitched draft")
            let unswitchedHead=try await unswitchedRepo.run(["rev-parse","HEAD"]).stdout
            unswitchedModel.commit();try await wait{unswitchedOwner.detachedQuestion != nil};unswitchedOwner.detachedQuestion!.buttons[0].performClick(nil)
            try await wait{unswitchedOwner.detachedBranch?.model.canEditForm==true}
            let unswitchedChild=unswitchedOwner.detachedBranch!;unswitchedChild.model.options.name="created-only";unswitchedChild.model.switchAfterCreation=false;unswitchedChild.model.create()
            try await wait{unswitchedOwner.detachedBranch==nil && unswitchedOwner.detachedQuestion != nil}
            let stillDetached=try await unswitchedRepo.branch(),stillHead=try await unswitchedRepo.run(["rev-parse","HEAD"]).stdout,createdOnly=try await unswitchedRepo.run(["rev-parse","refs/heads/created-only"]).stdout
            try require(stillDetached.isEmpty && stillHead==unswitchedHead && createdOnly==unswitchedHead && unswitchedModel.commitProgress==nil,"Unswitched branch silently continued a detached Commit")
            unswitchedOwner.detachedQuestion!.buttons[2].performClick(nil);try await wait{!unswitchedModel.busy}
            try require(unswitchedModel.message=="Unswitched draft","Reoffered warning dropped Commit draft")

            // Force close while the actual owned Branch child is awaiting an
            // asynchronous preparation response. Both owners retain drain
            // accounting, reject late results and never create the reference.
            let forcedRepo=try await fixture(parent,git:git,name:"forced-branch"),forcedOwner=owner(forcedRepo),forcedModel=forcedOwner.model
            try await prepare(forcedOwner);let forcedBefore=try await witness(forcedRepo)
            forcedModel.commit();try await wait{forcedOwner.detachedQuestion != nil};forcedOwner.detachedQuestion!.buttons[0].performClick(nil)
            try await wait{forcedOwner.detachedBranch?.model.canEditForm==true}
            let forcedChild=forcedOwner.detachedBranch!
            var prepared:CheckedContinuation<ReferenceCreationPlan,Error>?,childToken:OperationCancellation?,forcedClosed=0
            forcedChild.model.prepareReference={_,token in childToken=token;return try await withCheckedThrowingContinuation{prepared=$0}}
            unblock.append{let reply=prepared;prepared=nil;reply?.resume(throwing:OperationCancellationFailure.cancelled)}
            forcedChild.model.options.name="never-created";forcedChild.model.create();try await wait{childToken != nil}
            forcedOwner.onClosed={forcedClosed += 1};forcedOwner.close()
            try require(childToken?.isCancelled==true && forcedClosed==0 && BranchTagWindowModel.activeCreations>0,"Forced parent abandoned live owned Branch preparation")
            let preparedReply=prepared;prepared=nil;preparedReply?.resume(throwing:OperationCancellationFailure.cancelled)
            try await wait{forcedClosed==1 && forcedOwner.detachedBranch==nil && BranchTagWindowModel.activeCreations==0 && CommitWindowModel.activeCommitPreflights==0}
            let afterForced=try await witness(forcedRepo)
            try require(afterForced==forcedBefore,"Closed Branch child published late reference/Commit work")

            // An explicit Commit new-branch choice already supplies the source
            // branch/switch route and must not show a redundant detached prompt.
            let explicitRepo=try await fixture(parent,git:git,name:"explicit-new-branch"),explicitOwner=owner(explicitRepo),explicitModel=explicitOwner.model
            try await prepare(explicitOwner,message:"Explicit branch commit")
            var redundant=0
            explicitModel.confirmDetachedHead={_ in redundant += 1;return .cancel}
            explicitModel.createBranch=true;explicitModel.newBranch="explicit/topic";explicitModel.commit()
            try await wait{!explicitModel.busy && CommitWindowModel.activeCommitPreflights==0}
            let explicitBranch=try await explicitRepo.branch()
            try require(redundant==0 && explicitBranch=="explicit/topic","Explicit new branch triggered redundant detached warning or failed to switch")

            // A delayed authoritative branch read remains owned after force
            // close and must reject its eventual detached value.
            let lateRepo=try await fixture(parent,git:git,name:"late-read"),lateOwner=owner(lateRepo),lateModel=lateOwner.model
            try await prepare(lateOwner);let lateBefore=try await witness(lateRepo)
            var continuation:CheckedContinuation<String,Error>?,readToken:OperationCancellation?,latePrompts=0,closed=0
            lateModel.readCommitBranch={token in readToken=token;return try await withCheckedThrowingContinuation{continuation=$0}}
            lateModel.confirmDetachedHead={_ in latePrompts += 1;return .continueDetached};lateOwner.onClosed={closed += 1}
            unblock.append{let done=continuation;continuation=nil;done?.resume(returning:"")}
            lateModel.commit();try await wait{readToken != nil};lateOwner.close()
            try require(readToken?.isCancelled==true && closed==0 && CommitWindowModel.activeCommitPreflights>0,"Forced-close abandoned the owned authoritative branch reader")
            let done=continuation;continuation=nil;done?.resume(returning:"")
            try await wait{closed==1 && CommitWindowModel.activeCommitPreflights==0}
            let afterLateRead=try await witness(lateRepo)
            try require(latePrompts==0 && afterLateRead==lateBefore,"Late detached read prompted or committed after closure")

            // A native warning callback arriving after forced owner closure is
            // rejected and cannot create a child or continue a commit.
            let answerRepo=try await fixture(parent,git:git,name:"late-answer"),answerOwner=owner(answerRepo),answerModel=answerOwner.model
            try await prepare(answerOwner);let answerBefore=try await witness(answerRepo)
            var answer:((NSApplication.ModalResponse)->Void)?
            answerOwner.presentDetachedQuestion={_,_,reply in answer=reply;return true}
            answerModel.commit();try await wait{answer != nil};answerOwner.close();answer?(.alertFirstButtonReturn)
            try await wait{CommitWindowModel.activeCommitPreflights==0 && answerOwner.detachedQuestion==nil && answerOwner.detachedBranch==nil}
            let afterLateAnswer=try await witness(answerRepo)
            try require(afterLateAnswer==answerBefore,"Late Yes mutated the closed request")
            await cleanup();try require(drained(),"Detached-family workers did not drain")
            print("PASS: actual detached warning Cancel/No, real Create Branch/switch/Commit, branch Cancel/retry, explicit-new-branch suppression, captured author/date/draft preservation, late read/answer rejection, forced close/Quit ownership; private repositories and hidden owned windows")
        } catch {await cleanup();prefs.removePersistentDomain(forName:suite);throw error}
        prefs.removePersistentDomain(forName:suite);prefs.synchronize()
    }
    static func history()async throws {
        let parent=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),suite="TurtleGit.CommitCancelledIssue."+UUID().uuidString,prefs=preferences(suite)
        prefs.set(false,forKey:"Commit.SkipCancelConfirmation")
        var owners:[CommitWindowController]=[]
        func cleanup()async {owners.forEach{$0.close()};for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}}
        do {
            for (name,append,message,id,expected) in [("append",true,"Draft body"," 73, 42 ,9 ","Draft body\nRefs: 73,42,9\n"),("prepend",false,"Draft body"," 73 ","Refs: 73\nDraft body"),("issue-only",true,""," 73 ","\nRefs: 73\n"),("existing",true,"Draft body\nRefs: 73\n","73","Draft body\nRefs: 73\n\nRefs: 73\n"),("invalid-id",true,"Draft body"," ticket-A ","Draft body\nRefs: ticket-A\n")] {
                let repo=try await fixture(parent,git:git,name:name,detach:false)
                _=try await repo.run(["config","bugtraq.message","Refs: %BUGID%"]);_=try await repo.run(["config","bugtraq.append",append ? "true":"false"])
                let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs);owners.append(owner);try await prepare(owner)
                let model=owner.model;model.message=message;model.issueID=id
                let before=try await witness(repo),historyBefore=model.messageHistory?.entries ?? []
                var asks=0,answers:[Bool]=[],pending:((Bool)->Void)?
                model.confirmCancel={reply in asks += 1;pending=reply}
                model.cancel(closeWindow:false){answers.append($0)}
                try require(asks==1 && pending != nil && answers.isEmpty,"Issue-only/changed draft did not request cancellation confirmation")
                pending?(false);pending=nil
                try require(answers==[false] && model.message==message && model.issueID==id && model.messageHistory?.entries==historyBefore,"Rejected cancellation mutated visible draft or history")
                model.cancel(closeWindow:false){answers.append($0)};pending?(false);pending=nil
                try require(answers==[false,false] && model.message==message && model.messageHistory?.entries==historyBefore,"Repeated rejected cancellation duplicated issue lines")
                model.cancel(closeWindow:false){answers.append($0)};pending?(true);pending=nil
                try require(answers==[false,false,true] && model.messageHistory?.entries.first==expected && model.message==message && model.issueID==id,"Accepted cancellation dropped/rewrote recovered issue history")
                // Repeating the nonclosing Quit-style save does not modify the
                // draft or generate an additional issue line in history.
                model.cancel(closeWindow:false){answers.append($0)};pending?(true);pending=nil
                let afterHistory=try await witness(repo)
                try require(model.messageHistory?.entries.filter{$0==expected}.count==1 && afterHistory==before,"Repeated accepted cancellation duplicated history or mutated repository")
                owner.close()
            }

            // Entering Amend retains the ordinary draft separately. Cancel
            // recovers both messages, adding the current issue only to the
            // edited amend message as the source OnCancel path does.
            let amendRepo=try await fixture(parent,git:git,name:"amend-history",detach:false)
            _=try await amendRepo.run(["config","bugtraq.message","Refs: %BUGID%"])
            let amendOwner=CommitWindowController(repository:amendRepo,access:nil,defaults:prefs);owners.append(amendOwner)
            try await prepare(amendOwner,message:"Retained non-amend draft")
            let amendModel=amendOwner.model;amendModel.amend=true
            try await wait{!amendModel.loadingAmendMessage && amendModel.message.contains("Baseline safety fixture")}
            // Loading the amend message starts author/date reads and its status
            // comparison reload. Cancel owns/drains those asynchronously; wait
            // for the ready form before testing the idle history-save path.
            try await ready(amendModel)
            amendModel.message="Edited amend draft";amendModel.issueID="731";amendModel.confirmCancel={$0(true)}
            var amendAccepted:Bool?
            amendModel.cancel(closeWindow:false){amendAccepted=$0}
            try await wait{amendAccepted != nil}
            print("Amend recovery: accepted=\(String(describing:amendAccepted)), entries=\(amendModel.messageHistory?.entries ?? []), message=\(amendModel.message.debugDescription), issue=\(amendModel.issueID.debugDescription), busy=\(amendModel.busy), authorRead=\(amendModel.loadingAuthorIdentity), dateRead=\(amendModel.loadingAuthorDate), amendRead=\(amendModel.loadingAmendMessage)")
            try require(amendAccepted==true && amendModel.messageHistory?.entries.contains("Edited amend draft\nRefs: 731\n")==true && amendModel.messageHistory?.entries.contains("Retained non-amend draft")==true,"Amend cancellation dropped current issue message or retained ordinary draft")
            amendOwner.close()

            await cleanup();try require(drained(),"Cancelled-history workers did not drain")
            print("PASS: cancelled issue-ID history append/prepend/comma normalization, issue-only drafts and source duplicate-line behavior; rejected/repeated confirmations preserve visible drafts, accepted nonclosing cancellation deduplicates history, HEAD/index/source/config unchanged")
        } catch {await cleanup();prefs.removePersistentDomain(forName:suite);throw error}
        prefs.removePersistentDomain(forName:suite);prefs.synchronize()
    }
}
