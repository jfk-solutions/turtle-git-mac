import AppKit
import TurtleGitCore

@MainActor enum BranchTagPlanFixture {
    static func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:message,code:1)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:message,code:2)}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func repository(_ name:String)async throws->(GitRepository,String,String){
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name),git=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:git);_ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Progress family"),("user.email","progress@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);_ = try await repo.run(["branch","older",base])
        try Data("next\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"next")
        let next=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        return(repo,base,next)
    }
    static func parent()->NSWindow{
        let owner=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:750,height:450),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.appearance=NSAppearance(named:.darkAqua);return owner
    }
    static func attach(_ child:NSWindow?,to parent:NSWindow){if let child{child.alphaValue=parent.alphaValue;child.appearance=parent.appearance;parent.beginSheet(child,completionHandler:nil)}}
    static func output(_ window:NSWindow?,text:String,range:NSRange?,percentage:Int?,success:Bool,preferences:UserDefaults,clipboard:NSPasteboard)async throws{
        try await wait("Native styled progress output did not update"){window?.contentView?.layoutSubtreeIfNeeded();return views(window?.contentView).compactMap{$0 as? SubmoduleProgressTextView}.first?.string==text}
        let field=views(window?.contentView).compactMap{$0 as? SubmoduleProgressTextView}.first!
        try require(range != nil && percentage==100 && NSMaxRange(range!)<=field.textStorage!.length,"Command receipt lost terminal100 or footer range")
        let caption=(text as NSString).substring(with:range!)
        try require(success ? caption.contains("Success") : ["git did not exit cleanly","Operation failed","User cancelled"].contains(where:caption.contains),"Wrong command completion footer: \(caption)")
        let color=field.textStorage!.attribute(.foregroundColor,at:range!.location,effectiveRange:nil) as? NSColor
        for mode in [NSAppearance.Name.aqua,.darkAqua]{NSAppearance(named:mode)!.performAsCurrentDrawingAppearance{
            let expected=success ? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.textColor:SubmoduleProgressTextView.successColor:SubmoduleProgressTextView.color(error:true)
            precondition(color?.usingColorSpace(.sRGB)==expected.usingColorSpace(.sRGB),"Progress footer color differs in \(mode)")
        }}
        try require(!field.isEditable && field.isSelectable && field.preferences===preferences && field.clipboard===clipboard,"Progress lost native selection or private captured preferences/clipboard: editable=\(field.isEditable),selectable=\(field.isSelectable),samePreferences=\(field.preferences===preferences),sameClipboard=\(field.clipboard===clipboard)")
        let selected=NSRange(location:0,length:min(4,(text as NSString).length));field.setSelectedRange(selected);field.copyAllInformation(nil)
        try require(clipboard.string(forType:.string)==text && field.selectedRange()==selected,"Progress Copy All changed bytes/selection")
    }
    static func wrapper(_ repo:GitRepository,command:String) throws->(GitRepository,URL,URL){
        let file=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("held-"+command),marker=URL(fileURLWithPath:file.path+".started"),release=URL(fileURLWithPath:file.path+".release")
        let git=repo.executable.path.replacingOccurrences(of:"'",with:"'\\''")
        let script="""
        #!/bin/sh
        task_command() {
          if [ "${1-}" = --literal-pathspecs ] || [ "${1-}" = --no-literal-pathspecs ]; then shift; fi
          if [ "${1-}" = -C ]; then shift 2; fi
          while [ "${1-}" = -c ]; do shift 2; done
          test "${1-}" = '\(command)'
        }
        if task_command "$@" && [ ! -f "$0.release" ]; then
          printf 'Updating files:  50%% (1/2)\\r' >&2
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started.tmp"
          /bin/mv "$0.started.tmp" "$0.started"
          wait "$task_child"
        fi
        exec '\(git)' "$@"
        """
        try script.write(to:file,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        return(GitRepository(root:repo.root,executable:file),marker,release)
    }
}

@MainActor final class BranchTagQuestions {
    var entries:[(BranchTagQuestion,NSAlert,(NSApplication.ModalResponse)->Void)]=[]
    var last:(BranchTagQuestion,NSAlert,(NSApplication.ModalResponse)->Void)?{entries.last}
    func install(_ owner:BranchTagWindowController){owner.presentQuestion={ [self] kind,alert,window,reply in entries.append((kind,alert,reply));alert.beginSheetModal(for:window,completionHandler:reply)}}
}
struct BranchTagPlanFamilyVerification {
    @MainActor static func verify()async throws {
        typealias F=BranchTagPlanFixture
        let suite="TurtleGit.BranchTagPlans."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"NewBranchSwitchTo");prefs.set(false,forKey:"PushTag");prefs.set(true,forKey:"ConfirmKillProcess")
        defer{prefs.removePersistentDomain(forName:suite)}
        let(repo,_,_)=try await F.repository("reference plans")
        _ = try await repo.run(["tag","--no-sign","shared","HEAD"])
        let initialRefs=try await repo.run(["show-ref"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        let owner=BranchTagWindowController(repository:repo,access:RepositoryAccessLease(url:repo.root),isTag:false,preferences:prefs),questions=BranchTagQuestions()
        owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua);questions.install(owner);defer{owner.close()}
        var closed=0;owner.onClosed={closed+=1};owner.model.load(revision:"HEAD")
        try await F.wait("Branch options metadata did not drain"){!owner.model.busy && !owner.model.chooser.busy}
        owner.model.options.name="--invalid";owner.model.switchAfterCreation=false;owner.model.create()
        try await F.wait("Invalid branch did not present owned error"){if case .error(_)?=questions.last?.0{return owner.questionWindow?.sheetParent===owner.window};return false}
        try F.require(prefs.bool(forKey:"NewBranchSwitchTo"),"Invalid preflight persisted unchecked Switch option")
        questions.last!.1.buttons[0].performClick(nil)
        try await F.wait("Invalid error did not actually detach"){owner.questionWindow==nil && owner.window?.attachedSheet==nil}
        owner.model.options.name="shared";owner.model.create()
        try await F.wait("Cross-name warning did not attach"){questions.last?.0 == .nameConflict && owner.questionWindow?.sheetParent===owner.window}
        let abort=questions.last!
        try F.require(abort.1.buttons.map{$0.title}==["Continue","Abort"] && abort.1.window.defaultButtonCell === (abort.1.buttons[1].cell as? NSButtonCell),"Cross-name Abort was not actual native default")
        try F.require(prefs.bool(forKey:"NewBranchSwitchTo") && !owner.windowShouldClose(owner.window!),"Unanswered cross-name warning saved preference or released owner")
        abort.1.buttons[1].performClick(nil);abort.2(.alertFirstButtonReturn)
        try await F.wait("Cross-name Abort did not drain"){owner.questionWindow==nil && !owner.model.hasPendingNameConflict && !owner.model.busy}
        let abortedRefs=try await repo.run(["show-ref"]).stdout
        try F.require(abortedRefs==initialRefs && prefs.bool(forKey:"NewBranchSwitchTo") && closed==0,"Cross-name Abort/duplicate Continue mutated reference/preference or closed options")
        owner.model.create();try await F.wait("Cross-name Continue warning missing"){questions.last?.0 == .nameConflict && owner.questionWindow != nil}
        let proceed=questions.last!;proceed.1.buttons[0].performClick(nil);proceed.2(.alertSecondButtonReturn)
        try await F.wait("Accepted branch creation did not settle/close"){closed==1 && !owner.model.hasPendingWork && owner.questionWindow==nil && owner.window?.attachedSheet==nil}
        let branch=try await repo.run(["rev-parse","refs/heads/shared"]).stdout,tag=try await repo.run(["rev-parse","refs/tags/shared"]).stdout
        try F.require(branch==tag && !prefs.bool(forKey:"NewBranchSwitchTo"),"Accepted validated branch did not persist captured Switch option or correct target")
        try await verifyFailureAndRetirement(repo:repo,preferences:prefs)
        try await verifyHeldPreparation(repo:repo,preferences:prefs)
        let finalIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        try F.require(finalIndex==index,"Branch/Tag creation changed index")
        print("Branch/Tag native owned invalid/cross-name/error questions/default Abort, accepted-plan preference timing, failed mutation persistence and held worker/preflight/Quit/retirement passed.")
    }
    @MainActor static func verifyFailureAndRetirement(repo:GitRepository,preferences:UserDefaults)async throws {
        typealias F=BranchTagPlanFixture
        let owner=BranchTagWindowController(repository:repo,access:nil,isTag:true,preferences:preferences),questions=BranchTagQuestions()
        owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua);questions.install(owner);defer{owner.close()}
        owner.model.load(revision:"HEAD");try await F.wait("Tag options did not load"){!owner.model.busy && !owner.model.chooser.busy}
        owner.model.options.name="bad-base-accepted";owner.model.pushAfterCreation=true
        owner.model.useHead=false;owner.model.chooser.options.target = .commit;owner.model.chooser.commitRevision="missing-reference"
        owner.model.create()
        try await F.wait("Accepted invalid base did not show owned error"){if case .error(_)?=questions.last?.0{return owner.questionWindow != nil};return false}
        try F.require(preferences.bool(forKey:"PushTag"),"Source accepted-form Push preference was not saved before base resolution failed")
        questions.last!.1.buttons[0].performClick(nil);try await F.wait("Invalid base error did not detach"){owner.questionWindow==nil}
        owner.model.useHead=true;owner.model.options.name="failed-accepted"
        var pending:CheckedContinuation<String,Error>?,token:OperationCancellation?,closed=0,pushes=0
        defer{pending?.resume(throwing:OperationCancellationFailure.cancelled);pending=nil}
        owner.onClosed={closed+=1};owner.model.onPushTag={_ in pushes+=1}
        owner.model.performReference={plan,request in token=request;return try await withCheckedThrowingContinuation{pending=$0;_ = plan}}
        owner.model.create();try F.require(owner.model.hasPendingWork,"Reference create did not synchronously reserve work")
        try await F.wait("Accepted reference did not reach held mutation"){pending != nil}
        try F.require(preferences.bool(forKey:"PushTag"),"Accepted validated Tag did not save Push preference before mutation")
        try F.require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped held Tag mutation")
        pending?.resume(throwing:GitFailure(arguments:["tag"],code:17,message:"controlled accepted mutation failure"));pending=nil
        try await F.wait("Mutation failure did not show actual error"){if case .error(_)?=questions.last?.0{return owner.questionWindow != nil};return false}
        try F.require(preferences.bool(forKey:"PushTag") && pushes==0,"Actual mutation failure rolled back accepted preference or opened Push")
        questions.last!.1.buttons[0].performClick(nil);try await F.wait("Mutation error did not detach"){owner.questionWindow==nil}
        owner.model.options.name="retired-held";owner.model.pushAfterCreation=false;owner.model.create()
        try await F.wait("Retirement mutation did not start"){pending != nil}
        owner.close();try F.require(closed==0 && owner.model.hasPendingWork && token?.isCancelled==true,"Forced reference close released noncooperative actual worker early")
        pending?.resume(returning:"late success");pending=nil
        try await F.wait("Retired reference worker did not actually close"){closed==1 && !owner.model.hasPendingWork && owner.window?.attachedSheet==nil && BranchTagWindowController.activeReleases==0}
        try F.require(pushes==0 && !owner.model.active,"Retired reference emitted late Push")
        let absent=try await repo.run(["show-ref","--verify","--quiet","refs/tags/retired-held"],successfulExitCodes:0...1)
        try F.require(absent.exitCode==1,"Synthetic retired worker caused real reference mutation")
    }
    @MainActor static func verifyHeldPreparation(repo:GitRepository,preferences:UserDefaults)async throws {
        typealias F=BranchTagPlanFixture
        preferences.set(false,forKey:"NewBranchSwitchTo")
        let owner=BranchTagWindowController(repository:repo,access:nil,isTag:false,preferences:preferences)
        owner.window?.alphaValue=0;defer{owner.close()};owner.model.load(revision:"HEAD")
        try await F.wait("Held preflight options did not load"){!owner.model.busy && !owner.model.chooser.busy}
        owner.model.options.name="never-performed";owner.model.switchAfterCreation=true
        var options=ReferenceCreationOptions();options.name="never-performed"
        let form=try await repo.prepareReferenceCreationForm(options)
        var reply:CheckedContinuation<ReferenceCreationForm,Error>?,token:OperationCancellation?,closed=0,mutations=0
        defer{reply?.resume(throwing:OperationCancellationFailure.cancelled);reply=nil}
        owner.onClosed={closed+=1};owner.model.prepareForm={_,request in token=request;return try await withCheckedThrowingContinuation{reply=$0}}
        owner.model.performReference={_,_ in mutations+=1;return "unexpected"}
        let old=owner.model.option(\.name,context:owner.model.formContext)
        owner.model.create();try F.require(owner.model.hasPendingWork,"Preparation admission was not synchronous")
        old.wrappedValue="stale name"
        try await F.wait("Reference preflight was not held"){reply != nil}
        try F.require(!preferences.bool(forKey:"NewBranchSwitchTo") && owner.model.options.name=="never-performed","Unvalidated plan saved preference or accepted stale binding")
        try F.require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped held reference preflight")
        owner.close();try F.require(closed==0 && owner.model.hasPendingWork && token?.isCancelled==true,"Forced close dropped held preflight ownership")
        reply?.resume(returning:form);reply=nil
        try await F.wait("Retired preflight did not release owner"){closed==1 && !owner.model.hasPendingWork && BranchTagWindowController.activeReleases==0}
        try F.require(mutations==0 && !preferences.bool(forKey:"NewBranchSwitchTo"),"Retired preflight persisted or mutated after late valid plan")
    }

}
