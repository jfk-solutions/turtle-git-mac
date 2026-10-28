// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum CommitResultVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {if !condition {throw Failure(description:"\(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Commit result timeout at \(line)")
    }
    static func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func ready(_ model:CommitWindowModel,allowError:Bool = false)async throws {
        try await wait{!model.busy && model.commitIdentityPrepared && model.changelistsLoaded && !model.loadingAuthorIdentity && !model.loadingAuthorDate && !model.loadingAmendMessage && (allowError || model.error==nil)}
    }
    static func drained()->Bool {CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeFileOperations==0 && ClientHookSession.activeOperations==0 && ClientHookSession.activeQuestionReleases==0 && ClientHookProcessPool.shared.activeScripts==0}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite:String
        let prefs:UserDefaults
        var owners:[CommitWindowController]=[],unblock:[()->Void]=[]
        init(){let name="TurtleGit.CommitResult."+UUID().uuidString;suite=name;prefs=UserDefaults(suiteName:name)!;for key in ["HintHierarchicalConfig","HintStagingMode","Commit.SkipCancelConfirmation"]{prefs.set(true,forKey:key)};for key in ["EnableGravatar","AddBeforeCommit","ConfirmKillProcess"]{prefs.set(false,forKey:key)};prefs.set(0,forKey:"AutoCloseGitProgress")}
        func owner(_ repo:GitRepository)->CommitWindowController {
            let value=CommitWindowController(repository:repo,access:nil,defaults:prefs);owners.append(value)
            value.window?.alphaValue=0;value.window?.setFrameOrigin(.init(x:-12000,y:-12000));value.window?.orderFront(nil)
            return value
        }
        func cleanup()async {unblock.forEach{$0()};unblock=[];owners.forEach{$0.close()};for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};owners.forEach{$0.window?.orderOut(nil)};prefs.removePersistentDomain(forName:suite);prefs.synchronize()}
        func fixture(_ name:String)async throws->GitRepository {
            let directory=root.appendingPathComponent(name,isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let repo=GitRepository(root:directory,executable:git,askpass:nil)
            _=try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Commit result QA"),("user.email","result@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","false")] {_=try await repo.run(["config",key,value])}
            try Data("base\n".utf8).write(to:directory.appendingPathComponent("tracked.txt"));try await repo.stage(["tracked.txt"]);_=try await repo.commit(message:"Baseline result fixture")
            try Data("all working edits\n".utf8).write(to:directory.appendingPathComponent("tracked.txt"))
            return repo
        }
    }
    static func run(_ body:(Context)async throws->Void)async throws {
        let context=Context()
        do {try await body(context);await context.cleanup();try require(drained(),"Commit result workers failed to drain")}
        catch {await context.cleanup();throw error}
    }
    static func prepare(_ owner:CommitWindowController,message:String)async throws {
        owner.model.reload(paths:["."]);try await ready(owner.model);owner.model.message=message;owner.model.checked=["tracked.txt"];try await wait{owner.model.canCommit}
    }
    static func savedPartial(_ owner:CommitWindowController,repo:GitRepository)async throws {
        let model=owner.model
        model.withFileMenu(model.fileMenu(["tracked.txt"])) {model.markForRestore(["tracked.txt"])}
        try await ready(model);try require(model.restoreCopies["tracked.txt"] != nil,"Actual saved working-copy capture missing")
        try Data("chosen commit edits\n".utf8).write(to:repo.root.appendingPathComponent("tracked.txt"));model.reload();try await ready(model);model.checked=["tracked.txt"]
    }
    static func executable(_ text:String,at path:URL)throws {try Data(text.utf8).write(to:path);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path)}
    static func installPostHook(_ model:CommitWindowModel,repo:GitRepository,exit:Int = 0)throws->URL {
        let script=repo.root.appendingPathComponent(".git/client-post.sh"),marker=repo.root.appendingPathComponent(".git/client-post-observed")
        try executable("#!/bin/sh\nset -eu\n/bin/cat \"$1/tracked.txt\" > \"$1/.git/client-post-observed\"\nexit \(exit)\n",at:script)
        model.clientHooks.readProjectHooks={_,_ in [.init(type:.postCommit,path:repo.root.path,command:"/bin/sh "+quote(script.path),wait:true,show:false,local:false)]}
        return marker
    }
    static func restoration()async throws {try await run {context in
        for (name,hookExit) in [("restored-before-post",0),("post-failed-after-restore",23)] {
            let repo=try await context.fixture(name),owner=context.owner(repo),model=owner.model
            try await prepare(owner,message:"Restored partial commit");try await savedPartial(owner,repo:repo)
            let marker=try installPostHook(model,repo:repo,exit:hookExit)
            var progress:CommitProgressWindowModel?;model.onCommitProgress={progress=$0}
            model.commit();try await wait{progress?.busy==false}
            let headBytes=try await repo.run(["show","HEAD:tracked.txt"]).stdout,working=try Data(contentsOf:repo.root.appendingPathComponent("tracked.txt")),observed=try Data(contentsOf:marker)
            try require(progress?.success==true && model.busy && model.restoreCopies.isEmpty && headBytes==Data("chosen commit edits\n".utf8) && working==Data("all working edits\n".utf8) && observed==working,"Progress acknowledgement or client post-hook ran before saved working-copy restoration")
            try require(progress?.presentationPreferences === context.prefs && owner.window?.alphaValue==0,"Commit result lost captured preferences/invisible ownership")
            progress?.choose(nil)
            if hookExit != 0 {try await ready(model,allowError:true);try require(model.error?.contains("post-commit hook failed")==true && model.messageFocusAvailable,"Failed post-hook hid successful Git result or retired recoverable owner")}
            else {try await wait{!model.busy && CommitWindowModel.activeCommitPreflights==0}}
            let after=try await repo.run(["show","HEAD:tracked.txt"]).stdout;try require(after==headBytes,"Acknowledgement/post-hook failure rewrote successful commit")
        }
        // Git's own post-commit hook can change HEAD and then cause Git's
        // final refresh to fail. This is an actual failed command with a new
        // commit, not a successful native restoration failure.
        let plainRepo=try await context.fixture("git-error-after-head"),receiptWrapper=context.root.appendingPathComponent("git-commit-exit-receipt")
        let receiptScript="""
        #!/bin/sh
        if [ "${4-}" = commit ]; then
          \(quote(context.git.path)) "$@"
          task_commit_exit=$?
          printf '%s' "$task_commit_exit" > "$3/.git/actual-commit-exit"
          exit "$task_commit_exit"
        fi
        exec \(quote(context.git.path)) "$@"
        """
        try executable(receiptScript,at:receiptWrapper)
        let repo=GitRepository(root:plainRepo.root,executable:receiptWrapper,askpass:nil),owner=context.owner(repo),model=owner.model
        try await prepare(owner,message:"Commit before Git final-refresh error");try await savedPartial(owner,repo:repo)
        let marker=try installPostHook(model,repo:repo),hooks=repo.root.appendingPathComponent(".git/private-hooks")
        try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:true)
        try executable("#!/bin/sh\nset -eu\nprintf called > .git/git-post-ran\n/bin/rm tracked.txt\n/bin/mkdir tracked.txt\n",at:hooks.appendingPathComponent("post-commit"));_=try await repo.run(["config","core.hooksPath",hooks.path])
        let previousHead=try await repo.run(["rev-parse","HEAD"]).stdout
        var progress:CommitProgressWindowModel?,recoveryChoices=0,allowsCancel:Bool?
        model.onCommitProgress={progress=$0};model.chooseRestoreCopies={allow,choose in recoveryChoices += 1;allowsCancel=allow;choose(.keep)}
        model.commit();try await wait{progress?.busy==false}
        let committed=try await repo.run(["show","HEAD:tracked.txt"]).stdout,changedHead=try await repo.run(["rev-parse","HEAD"]).stdout
        let actualExit=Int(try String(contentsOf:repo.root.appendingPathComponent(".git/actual-commit-exit"),encoding:.utf8))
        print("Git partial failure diagnostic: actualExit=\(String(describing:actualExit)), success=\(String(describing:progress?.success)), savedCopy=\(model.restoreCopies["tracked.txt"] != nil), clientMarker=\(FileManager.default.fileExists(atPath:marker.path)), HEADchanged=\(changedHead != previousHead), output=\(progress?.output ?? "none")")
        try require(actualExit != nil && progress?.success==(actualExit==0) && changedHead != previousHead && model.restoreCopies["tracked.txt"] != nil && !FileManager.default.fileExists(atPath:marker.path) && committed==Data("chosen commit edits\n".utf8),"Git result after new HEAD lost actual exit status/saved copy or ran client post-hook")
        if actualExit==0 {try require(progress?.output.contains("restoring saved working copies failed")==true,"Successful Git return did not report native restoration failure")}
        else {try require(progress?.output.contains("HEAD changed during the attempt")==true,"Failed Git command with changed HEAD omitted inspect-before-retry warning")}
        progress?.choose(nil);try await ready(model,allowError:true)
        try require(recoveryChoices==(actualExit==0 ? 0:1) && (actualExit==0 || allowsCancel==false) && model.messageFocusAvailable && model.messageHistory?.entries.contains("Commit before Git final-refresh error")==true,"Git partial result omitted its source Keep/restore recovery or attempted-message history")
        try FileManager.default.removeItem(at:repo.root.appendingPathComponent("tracked.txt"));try Data("obstruction repaired\n".utf8).write(to:repo.root.appendingPathComponent("tracked.txt"))
        model.error=nil;model.confirmFileRestore={true};model.restoreNow(["tracked.txt"]);try await ready(model)
        let recovered=try Data(contentsOf:repo.root.appendingPathComponent("tracked.txt")),retainedHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(model.restoreCopies.isEmpty && recovered==Data("all working edits\n".utf8) && retainedHead==changedHead,"Git partial-failure recovery auto-committed or lost saved working bytes")

        // Put the same genuine filesystem obstruction AFTER successful Git
        // return, at the explicit native restoration boundary. The seam invokes
        // the real restoration method, which rejects the directory destination.
        let nativeRepo=try await context.fixture("native-restore-failure"),nativeOwner=context.owner(nativeRepo),nativeModel=nativeOwner.model
        try await prepare(nativeOwner,message:"Successful commit before native restore error");try await savedPartial(nativeOwner,repo:nativeRepo)
        let nativeMarker=try installPostHook(nativeModel,repo:nativeRepo)
        var restoreCalls=0,nativeProgress:CommitProgressWindowModel?
        nativeModel.restoreWorkingCopy={copy,token in
            restoreCalls += 1
            if restoreCalls==1 {try FileManager.default.removeItem(at:nativeRepo.root.appendingPathComponent("tracked.txt"));try FileManager.default.createDirectory(at:nativeRepo.root.appendingPathComponent("tracked.txt"),withIntermediateDirectories:false)}
            try await nativeRepo.restoreWorkingFile(copy,cancellation:token)
        }
        nativeModel.onCommitProgress={nativeProgress=$0};nativeModel.commit();try await wait{nativeProgress?.busy==false}
        let nativeCommitted=try await nativeRepo.run(["show","HEAD:tracked.txt"]).stdout
        print("Native restore failure diagnostic: success=\(String(describing:nativeProgress?.success)), savedCopy=\(nativeModel.restoreCopies["tracked.txt"] != nil), clientMarker=\(FileManager.default.fileExists(atPath:nativeMarker.path)), calls=\(restoreCalls), output=\(nativeProgress?.output ?? "none")")
        try require(nativeProgress?.success==true && nativeModel.restoreCopies["tracked.txt"] != nil && !FileManager.default.fileExists(atPath:nativeMarker.path) && nativeCommitted==Data("chosen commit edits\n".utf8),"Native restore error lost successful commit/saved copy or ran client post-hook against obstruction")
        nativeProgress?.choose(nil);try await ready(nativeModel,allowError:true)
        try require(nativeModel.error?.contains("restor")==true && nativeModel.messageFocusAvailable,"Native restore error did not retain recoverable Commit owner")
        try FileManager.default.removeItem(at:nativeRepo.root.appendingPathComponent("tracked.txt"));try Data("obstruction repaired\n".utf8).write(to:nativeRepo.root.appendingPathComponent("tracked.txt"))
        nativeModel.error=nil;nativeModel.confirmFileRestore={true};nativeModel.restoreNow(["tracked.txt"]);try await ready(nativeModel)
        let restored=try Data(contentsOf:nativeRepo.root.appendingPathComponent("tracked.txt")),unchangedCommit=try await nativeRepo.run(["show","HEAD:tracked.txt"]).stdout
        try require(restoreCalls==2 && nativeModel.restoreCopies.isEmpty && restored==Data("all working edits\n".utf8) && unchangedCommit==nativeCommitted,"Native restoration retry failed or rewrote successful commit")
        print("PASS: real partial-copy restoration precedes client post-hook and unacknowledged progress; post-hook/native-restore failures retain successful commits and recovery; actual Git error after HEAD change warns before retry; both actual filesystem obstructions repaired and saved working copies restored without another commit")
    }}
    static func failure()async throws {try await run {context in
        let repo=try await context.fixture("failed-attempt"),owner=context.owner(repo),model=owner.model
        try await prepare(owner,message:"Retained ordinary draft")
        model.amend=true;try await wait{!model.loadingAmendMessage && model.message.contains("Baseline result fixture")};try await ready(model)
        model.message="Failed amended attempt";model.checked=["tracked.txt"]
        let hooks=repo.root.appendingPathComponent(".git/private-hooks");try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:true)
        try executable("#!/bin/sh\nprintf 'controlled Git pre-commit rejection\\n' >&2\nexit 31\n",at:hooks.appendingPathComponent("pre-commit"));_=try await repo.run(["config","core.hooksPath",hooks.path])
        let before=try await repo.run(["rev-parse","HEAD"]).stdout,history=model.messageHistory?.entries ?? []
        var progress:CommitProgressWindowModel?;model.onCommitProgress={progress=$0}
        model.commit();try await wait{progress?.busy==false}
        try require(progress?.success==false && model.busy && model.messageHistory?.entries==history,"Failed-attempt history was saved before source progress acknowledgement")
        progress?.choose(nil);try await ready(model,allowError:true)
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(before==after && model.messageHistory?.entries.contains("Failed amended attempt")==true && model.messageHistory?.entries.contains("Retained ordinary draft")==true,"Acknowledged failed Git attempt dropped attempted or retained ordinary draft history")
        let aborted=try await context.fixture("preflight-abort"),abortedOwner=context.owner(aborted),abortedModel=abortedOwner.model,template=aborted.root.appendingPathComponent(".git/template")
        try Data("Unchanged template".utf8).write(to:template);_=try await aborted.run(["config","commit.template",template.path])
        try await prepare(abortedOwner,message:"Unchanged template")
        // LoadTextFile's source normalization adds a final LF. Compare against
        // the actual raw template, not the visually equal trimmed editor text.
        try require(abortedModel.messageTemplate=="Unchanged template\n","Private template did not load with source final-LF normalization")
        abortedModel.message=abortedModel.messageTemplate;try await wait{abortedModel.canCommit}
        var warned=0;abortedModel.confirmUneditedTemplate={warned += 1;$0(false)};let abortedHistory=abortedModel.messageHistory?.entries
        print("Template preflight: template=\(abortedModel.messageTemplate.debugDescription), message=\(abortedModel.message.debugDescription), skip=\(context.prefs.bool(forKey:"Commit.TemplateNotEdited.Proceed")), canCommit=\(abortedModel.canCommit)")
        abortedModel.commit()
        do {try await wait{warned==1 && !abortedModel.busy && CommitWindowModel.activeCommitPreflights==0}}
        catch {print("Template abort diagnostic: warned=\(warned), busy=\(abortedModel.busy), progress=\(abortedModel.commitProgress != nil), error=\(abortedModel.error ?? "none"), activePreflights=\(CommitWindowModel.activeCommitPreflights)");throw error}
        try require(abortedModel.commitProgress==nil && abortedModel.messageHistory?.entries==abortedHistory,"Preflight abort was recorded as a failed Git attempt")
        print("PASS: actual rejecting Git hook preserves HEAD and records attempted/retained non-Amend drafts only after progress acknowledgement; unedited-template preflight abort creates no attempted-message history")
    }}
    static func editor()async throws {try await run {context in
        let repo=try await context.fixture("recommit-editor"),template=repo.root.appendingPathComponent(".git/template")
        try Data("New session template".utf8).write(to:template);_=try await repo.run(["config","commit.template",template.path]);_=try await repo.run(["config","bugtraq.message","Refs: %BUGID%"])

        let owner=context.owner(repo),model=owner.model,hook=repo.root.appendingPathComponent(".git/start-message.sh")
        try executable("#!/bin/sh\nset -eu\n/bin/cp \"$2\" \"$3/.git/start-input\"\nprintf x >> \"$3/.git/start-count\"\nprintf 'ReCommit Start-hook draft' > \"$2\"\n",at:hook)
        try await prepare(owner,message:"First editor draft")
        model.amend=true;try await wait{!model.loadingAmendMessage && model.message.contains("Baseline result fixture")};try await ready(model)
        model.setAuthor=true;model.setAuthorDate=true
        await Task.yield();try await Task.sleep(nanoseconds:100_000_000);try await ready(model)
        model.author="ReCommit author <recommit@example.invalid>";model.authorDate=Date(timeIntervalSince1970:1_700_000_000);model.issueID="731";model.checked=["tracked.txt"]
        // Install after initial loading: the actual second Start hook supplies
        // the accepted new session rather than just assigning model.message.
        model.clientHooks.readProjectHooks={_,_ in [.init(type:.startCommit,path:repo.root.path,command:"/bin/sh "+quote(hook.path),wait:true,show:false,local:false)]}
        guard let editor=views(owner.window?.contentView).compactMap({$0 as? CommitMessageTextView}).first else{throw Failure(description:"Actual Commit message editor missing")}
        try await wait{editor.isEditable && editor.string==model.message}
        guard let undo=editor.undoManager else{throw Failure(description:"Commit editor Undo manager missing")}
        undo.removeAllActions();editor.breakUndoCoalescing();editor.insertText("First editor draft edited",replacementRange:NSRange(location:0,length:(editor.string as NSString).length));editor.breakUndoCoalescing()
        try await wait{model.message=="First editor draft edited"};try require(undo.canUndo,"Native edit did not establish pre-Commit Undo")
        guard let foreignUndo=owner.window?.undoManager else{throw Failure(description:"Owning window Undo manager missing")}
        try require(foreignUndo !== undo,"Commit message does not own its Undo manager separately from other form controls")
        let foreignMarker=NSMutableString(string:"")
        foreignUndo.beginUndoGrouping();foreignUndo.registerUndo(withTarget:foreignMarker){$0.append("other form Undo retained")};foreignUndo.endUndoGrouping()
        let priorSession=model.messageEditorSession
        var progress:CommitProgressWindowModel?;model.onCommitProgress={progress=$0}
        model.commit(.recommit)
        try await wait{!model.busy && model.message=="ReCommit Start-hook draft" && editor.string==model.message && model.messageEditorSession != priorSession}
        let startInput=try String(contentsOf:repo.root.appendingPathComponent(".git/start-input"),encoding:.utf8),startCount=try Data(contentsOf:repo.root.appendingPathComponent(".git/start-count"))
        try require(progress?.success==true && !undo.canUndo && !model.amend && !model.setAuthor && !model.setAuthorDate && model.issueID=="731" && startInput=="New session template\n" && startCount==Data("x".utf8),"Amend→ReCommit retained old Undo/metadata, dropped issue ID, repeated Start hook or failed actual commit")
        try require(foreignUndo.canUndo,"ReCommit cleared unrelated form Undo")
        foreignUndo.undo();try require(foreignMarker as String=="other form Undo retained","Unrelated form Undo action was lost")
        @MainActor func editorState(_ phase:String) {
            print("ReCommit editor \(phase): model=\(model.message.debugDescription), editor=\(editor.string.debugDescription), editable=\(editor.isEditable), admitted=\(editor.messageLayoutAvailable), blocked=\(model.inputsBlocked), busy=\(model.busy), metadata=\(CommitWindowModel.activeMetadataOperations), preflights=\(CommitWindowModel.activeCommitPreflights), session=\(model.messageEditorSession), presentation=\(editor.messagePresentationSessionID), sameModel=\(editor.model === model), sameWindow=\(editor.window === owner.window), delegate=\(editor.delegate != nil), sheet=\(owner.window?.attachedSheet != nil)")
        }
        editorState("new session published")
        // The model can publish its accepted next session before SwiftUI has
        // enabled the installed native editor or the old Commit worker has
        // released its admission gate. User input is valid only after that
        // actual control admits editing; insertText is intentionally rejected
        // while the source owner still blocks input.
        do {
            try await wait{editor.model === model && editor.window === owner.window && editor.delegate != nil && editor.messageLayoutAvailable && editor.string==model.message}
        } catch {editorState("new session readiness timeout");throw error}
        editorState("new session ready")
        editor.breakUndoCoalescing();editor.insertText(" new edit",replacementRange:NSRange(location:(editor.string as NSString).length,length:0));editor.breakUndoCoalescing()
        do {try await wait{model.message=="ReCommit Start-hook draft new edit"}}catch{editorState("new session insertion timeout");throw error}
        try require(undo.canUndo,"New ReCommit session could not register Undo")
        undo.undo();try await wait{model.message=="ReCommit Start-hook draft" && editor.string==model.message}
        let currentSession=model.messageEditorSession
        try require(undo.canRedo,"New-session Undo did not retain its Redo before Refresh")
        try Data("second working change\n".utf8).write(to:repo.root.appendingPathComponent("tracked.txt"));model.reload();try await ready(model);model.checked=["tracked.txt"]
        try require(model.messageEditorSession==currentSession && undo.canRedo,"Ordinary Refresh reset the current message Undo/Redo session")
        let hooks=repo.root.appendingPathComponent(".git/failing-hooks");try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:true)
        try executable("#!/bin/sh\nexit 17\n",at:hooks.appendingPathComponent("pre-commit"));_=try await repo.run(["config","core.hooksPath",hooks.path])
        do {try await wait{editor.messageLayoutAvailable && editor.model === model && editor.string==model.message}}
        catch {editorState("post-refresh readiness timeout");throw error}
        editor.breakUndoCoalescing();editor.insertText(" retained failure edit",replacementRange:NSRange(location:(editor.string as NSString).length,length:0));editor.breakUndoCoalescing()
        try await wait{model.message=="ReCommit Start-hook draft retained failure edit"}
        print("Failed ReCommit before: model=\(model.message.debugDescription), editor=\(editor.string.debugDescription), selection=\(editor.selectedRange()), issue=\(model.issueID.debugDescription), canUndo=\(undo.canUndo), canRedo=\(undo.canRedo), session=\(model.messageEditorSession)")
        progress=nil;model.commit(.recommit);try await wait{progress?.busy==false}
        progress?.choose(nil);try await ready(model,allowError:true)
        print("Failed ReCommit acknowledgement view: editable=\(editor.isEditable), selectable=\(editor.isSelectable), firstResponderIsEditor=\(owner.window?.firstResponder === editor), ownerKey=\(owner.window?.isKeyWindow == true)")
        try await wait{editor.messageLayoutAvailable && editor.string==model.message && model.commitProgress==nil}
        print("Failed ReCommit acknowledged: editable=\(editor.isEditable), firstResponderIsEditor=\(owner.window?.firstResponder === editor), model=\(model.message.debugDescription), editor=\(editor.string.debugDescription), selection=\(editor.selectedRange()), issue=\(model.issueID.debugDescription), history=\(model.messageHistory?.entries ?? []), canUndo=\(undo.canUndo), canRedo=\(undo.canRedo), grouping=\(undo.groupingLevel), session=\(model.messageEditorSession)")
        try require(progress?.success==false && model.messageEditorSession==currentSession && undo.canUndo && model.message=="ReCommit Start-hook draft retained failure edit" && editor.string==model.message && model.issueID=="731" && model.messageHistory?.entries.first=="ReCommit Start-hook draft retained failure edit\nRefs: 731","Failed ReCommit rewrote raw editor/Undo or lost serialized attempted history")
        undo.undo();await Task.yield()
        print("Failed ReCommit after Undo: editable=\(editor.isEditable), firstResponderIsEditor=\(owner.window?.firstResponder === editor), model=\(model.message.debugDescription), editor=\(editor.string.debugDescription), selection=\(editor.selectedRange()), issue=\(model.issueID.debugDescription), history=\(model.messageHistory?.entries ?? []), canUndo=\(undo.canUndo), canRedo=\(undo.canRedo)")
        do {try await wait{model.message=="ReCommit Start-hook draft" && editor.string==model.message}}
        catch {print("Failed ReCommit Undo timeout: editable=\(editor.isEditable), firstResponderIsEditor=\(owner.window?.firstResponder === editor), model=\(model.message.debugDescription), editor=\(editor.string.debugDescription), issue=\(model.issueID.debugDescription), canUndo=\(undo.canUndo), canRedo=\(undo.canRedo)");throw error}
        print("PASS: actual NSTextView edits/Undo, real Git ReCommit plus accepted template/Start-hook new session clears old Undo; fresh session Undo works; ordinary Refresh and failed ReCommit retain current Undo/session")
    }}
    static func lifetime()async throws {try await run {context in
        let repo=try await context.fixture("retired-post-hook"),owner=context.owner(repo),model=owner.model
        try await prepare(owner,message:"Commit before pending post-hook");try await savedPartial(owner,repo:repo)
        var progress:CommitProgressWindowModel?,reply:CheckedContinuation<[ClientHook],Error>?,hookToken:OperationCancellation?,closed=0
        model.onCommitProgress={progress=$0}
        model.clientHooks.readProjectHooks={_,token in
            if progress != nil {hookToken=token;return try await withCheckedThrowingContinuation{reply=$0}}
            return []
        }
        context.unblock.append{let held=reply;reply=nil;held?.resume(returning:[])}
        owner.onClosed={closed += 1};model.commit();try await wait{hookToken != nil}
        let committed=try await repo.run(["show","HEAD:tracked.txt"]).stdout,restored=try Data(contentsOf:repo.root.appendingPathComponent("tracked.txt"))
        try require(committed==Data("chosen commit edits\n".utf8) && restored==Data("all working edits\n".utf8) && model.restoreCopies.isEmpty && progress?.busy==true,"Pending post-hook began before actual restoration/commit")
        owner.close()
        try require(hookToken?.isCancelled==true && closed==0 && ClientHookSession.activeOperations>0 && CommitWindowModel.activeCommitPreflights>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired Commit lost pending post-hook cancellation/Quit/drain ownership")
        let held=reply;reply=nil;held?.resume(returning:[])
        try await wait{closed==1 && ClientHookSession.activeOperations==0 && CommitWindowModel.activeCommitPreflights==0}
        let final=try await repo.run(["show","HEAD:tracked.txt"]).stdout
        try require(final==committed && !model.messageFocusAvailable,"Late post-hook result rewrote commit or revived retired editor")

        // A held saved-copy restoration owns its cancellation and outer Commit
        // lifetime even after the native owner is forcibly retired. The injected
        // scheduling boundary wraps the real restoration method, never a fake
        // successful write.
        let restoringRepo=try await context.fixture("retired-restoration"),restoringOwner=context.owner(restoringRepo),restoringModel=restoringOwner.model
        try await prepare(restoringOwner,message:"Commit before held restoration");try await savedPartial(restoringOwner,repo:restoringRepo)
        var restoreReply:CheckedContinuation<Void,Never>?,restoreToken:OperationCancellation?,restoreClosed=0,postReads=0
        restoringModel.restoreWorkingCopy={copy,token in
            restoreToken=token
            await withCheckedContinuation{restoreReply=$0}
            try token?.check();try await restoringRepo.restoreWorkingFile(copy,cancellation:token)
        }
        restoringModel.clientHooks.readProjectHooks={_,_ in postReads += 1;return []}
        context.unblock.append{let held=restoreReply;restoreReply=nil;held?.resume()}
        restoringOwner.onClosed={restoreClosed += 1};restoringModel.onCommitProgress={_ in};restoringModel.commit()
        try await wait{restoreReply != nil}
        let restoreCommitted=try await restoringRepo.run(["show","HEAD:tracked.txt"]).stdout
        let readsBeforeClose=postReads
        restoringOwner.close()
        try require(restoreToken?.isCancelled==true && restoreClosed==0 && CommitWindowModel.activeCommitPreflights>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired Commit dropped held restoration cancellation/Quit/drain ownership")
        let pendingRestore=restoreReply;restoreReply=nil;pendingRestore?.resume()
        try await wait{restoreClosed==1 && CommitWindowModel.activeCommitPreflights==0}
        let restoreFinal=try await restoringRepo.run(["show","HEAD:tracked.txt"]).stdout,restoreWorking=try Data(contentsOf:restoringRepo.root.appendingPathComponent("tracked.txt"))
        try require(restoreFinal==restoreCommitted && restoreWorking==Data("chosen commit edits\n".utf8) && restoringModel.restoreCopies["tracked.txt"] != nil && postReads==readsBeforeClose,"Late cancelled restoration wrote bytes, lost its recovery copy or ran post-hook work")

        print("PASS: actual commit/restoration before held post-hook configuration read, captured owner close cancels token, retains Quit/worker ownership until late callback drains, and preserves completed Git commit")
    }}
}
