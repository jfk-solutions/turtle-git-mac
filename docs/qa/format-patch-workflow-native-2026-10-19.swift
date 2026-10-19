import AppKit
import TurtleGitCore

@MainActor enum FormatPatchWorkflowFixture {
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

struct FormatPatchWorkflowVerification {
    @MainActor static func quote(_ value:String)->String {
        let safe="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.@:=+%,"
        return !value.isEmpty && value.utf8.allSatisfy{safe.utf8.contains($0)} ? value:"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"
    }
    @MainActor static func verify()async throws {
        typealias F=FormatPatchWorkflowFixture
        let suite="TurtleGit.FormatPatchWorkflow."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ShowGitexeTimings");prefs.set(true,forKey:"StyleGitOutput");prefs.set(true,forKey:"ConfirmKillProcess")
        defer{prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        let(repo,_,_)=try await F.repository("format workflow space"),root=URL(fileURLWithPath:CommandLine.arguments[1])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),working=try Data(contentsOf:repo.root.appendingPathComponent("file"))
        try await verifyMail(repo:repo,root:root,preferences:prefs,clipboard:clipboard)
        try await verifyHeldResult(repo:repo,root:root,preferences:prefs,clipboard:clipboard)
        try await verifyCancellationAndRetry(repo:repo,root:root,preferences:prefs,clipboard:clipboard)
        try await verifyQuitEpoch(repo:repo,root:root,preferences:prefs,clipboard:clipboard)
        try await verifyHeldPicker(repo:repo,root:root,preferences:prefs,clipboard:clipboard)
        let after=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),afterWorking=try Data(contentsOf:repo.root.appendingPathComponent("file"))
        try F.require(after==head && afterIndex==index && afterWorking==working,"Format Patch workflow changed source HEAD/index/working bytes")
        print("Format Patch exact command/native Copy/captured settings, actual progress detach before real mail, captured outputlease, held receipt/Quit/retirement, native No/Yes/stale answers and retry passed.")
    }
    @MainActor static func configure(_ owner:FormatPatchWindowController,directory:URL,clipboard:NSPasteboard,mail:Bool)async throws {
        typealias F=FormatPatchWorkflowFixture
        owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua);owner.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));owner.showWindow(nil)
        owner.model.outputClipboard=clipboard
        try await F.wait("Format Patch initial reads did not drain"){!owner.model.busy && !owner.model.hasPendingWork}
        owner.model.mode = .number;owner.model.count=1;owner.model.directory=directory.path;owner.model.sendMail=mail;owner.model.noPrefix=true
    }
    @MainActor static func verifyMail(repo:GitRepository,root:URL,preferences:UserDefaults,clipboard:NSPasteboard)async throws {
        typealias F=FormatPatchWorkflowFixture
        let directory=root.appendingPathComponent("mail patches '雪'\noutput"),lease=RepositoryAccessLease(url:directory),repoLease=RepositoryAccessLease(url:repo.root),wrong=RepositoryAccessLease(url:root.appendingPathComponent("wrong-output"))
        var owner:FormatPatchWindowController!,mail:SendPatchWindowController?,presented=0,closed=0
        owner=FormatPatchWindowController(repository:repo,access:repoLease,preferences:preferences,mailPresentation:{child in
            precondition(owner.progressController==nil && owner.window?.attachedSheet==nil && !owner.model.hasPendingWork)
            mail=child as? SendPatchWindowController;presented+=1
            child.window?.alphaValue=0;child.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));child.showWindow(nil)
        })
        defer{mail?.close();owner.close()};owner.onClosed={closed+=1}
        try await configure(owner,directory:directory,clipboard:clipboard,mail:true);owner.model.outputAccess=lease
        owner.model.export();try F.require(owner.model.hasPendingWork,"Format Patch export did not synchronously reserve work")
        owner.model.outputAccess=wrong;owner.model.directory=wrong.url.path;owner.model.count=3;owner.model.sendMail=false;owner.model.noPrefix=false
        try await F.wait("Real Format Patch result did not finish"){owner.progressController != nil && owner.model.commandFinished && !owner.model.hasPendingWork && !owner.model.busy}
        let progress=owner.progressController!
        let command=[repo.executable.path,"--literal-pathspecs","-C",repo.root.path,"format-patch","--no-prefix","-o",directory.standardizedFileURL.resolvingSymlinksInPath().path,"-1","--"].map(quote).joined(separator:" ")+"\n"
        try F.require(owner.model.output.hasPrefix(command),"Visible Format Patch command does not equal executed argv: \(owner.model.output.debugDescription)")
        try F.require(owner.model.commandSucceeded && owner.model.success && presented==0 && owner.model.submittedOutputAccess===lease,"Format Patch lost success/captured outputlease or bypassed acknowledgement")
        try await F.output(progress.window,text:owner.model.output,range:owner.model.completionRange,percentage:owner.model.percentage,success:true,preferences:preferences,clipboard:clipboard)
        try F.require(!(owner.model.output as NSString).substring(with:owner.model.completionRange!).contains(" ms @ "),"Format Patch ignored captured timing setting")
        owner.model.finish();owner.model.finish()
        try await F.wait("Actual Send Mail composer did not follow progress detach"){mail != nil && presented==1 && owner.progressController==nil && owner.window?.attachedSheet==nil}
        try F.require(mail!.model.presentationPreferences===preferences && mail!.window?.appearance?.name==NSAppearance.Name.darkAqua && mail!.window?.alphaValue==0,"Format Patch mail lost captured preferences/appearance")
        try await F.wait("Mail attachment preview did not drain"){SendPatchWindowModel.activeLoads==0 && !mail!.model.previewBusy}
        let files=mail!.model.rows.map(\.file),grants=try mail!.model.fileGrants(for:files)
        try F.require(files.count==1 && files[0].deletingLastPathComponent().path==directory.resolvingSymlinksInPath().path && grants.contains{$0===lease} && !grants.contains{$0===wrong},"Actual mail did not retain accepted output files/lease")
        let patch=try Data(contentsOf:files[0])
        try F.require(String(decoding:patch,as:UTF8.self).contains("Subject: [PATCH] next") && preferences.stringArray(forKey:"FormatPatchDirectories")?.first==directory.path,"Export/mail lost captured commit/output history")
        mail!.close();try await F.wait("Cancelling real mail options did not close Format Patch once"){closed==1 && !owner.model.composingMail && owner.window?.attachedSheet==nil}
        try F.require(presented==1 && (try Data(contentsOf:files[0]))==patch,"Mail cancellation changed generated patch bytes or repeated presentation")
    }
    @MainActor static func verifyHeldResult(repo:GitRepository,root:URL,preferences:UserDefaults,clipboard:NSPasteboard)async throws {
        typealias F=FormatPatchWorkflowFixture
        let owner=FormatPatchWindowController(repository:repo,access:nil,preferences:preferences)
        defer{owner.close()};try await configure(owner,directory:root.appendingPathComponent("held-result"),clipboard:clipboard,mail:true)
        let actionStore=ActionLogStore(storageURL:root.appendingPathComponent("held-result-actions.log"))
        ProgressActionLog.install(store:actionStore,preferences:preferences)
        var pending:CheckedContinuation<GitResult,Never>?,result:GitResult?,token:OperationCancellation?,closed=0,mail=0,refreshes=0
        defer{if let result{pending?.resume(returning:result)};pending=nil}
        owner.onClosed={closed+=1};owner.model.composeMail={_ in mail+=1};owner.model.onOutputChanged={_ in refreshes+=1}
        owner.model.runFormatPatch={selection,directory,noPrefix,request,output,command,finished in
            token=request
            let actual=try await repo.formatPatch(selection:selection,to:directory,noPrefix:noPrefix,cancellation:request,onOutput:output,onCommand:command,onCommandFinished:finished)
            result=actual;return await withCheckedContinuation{pending=$0}
        }
        owner.model.export();try await F.wait("Format Patch receipt did not precede held result discovery"){pending != nil && owner.model.commandFinished && owner.progressController != nil}
        try F.require(owner.model.commandSucceeded && owner.model.busy && owner.model.hasPendingWork && !owner.model.success && refreshes==0,"Command footer exposed workflow completion before result discovery")
        try await F.output(owner.progressController!.window,text:owner.model.output,range:owner.model.completionRange,percentage:owner.model.percentage,success:true,preferences:preferences,clipboard:clipboard)
        try F.require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped actual held Format Patch work")
        owner.model.cancelExport();try F.require(!owner.model.confirmingCancellation && owner.cancellationAlert==nil && token?.isCancelled==false,"Abort cancelled an already finished Git command during held result discovery")
        owner.model.finish();try F.require(mail==0,"Mail escaped held Format Patch result")
        owner.close();try F.require(closed==0 && owner.model.hasPendingWork && token?.isCancelled==true,"Forced Format Patch close released held worker early")
        pending?.resume(returning:result!);pending=nil
        try await F.wait("Retired Format Patch worker/progress did not actually drain"){closed==1 && !owner.model.hasPendingWork && owner.progressController==nil && owner.window?.attachedSheet==nil && FormatPatchWindowController.activeReleases==0}
        try F.require(mail==0 && refreshes==0 && owner.model.isRetired,"Retired Format Patch emitted mail/refresh callback")
        let logged=try actionStore.read()
        try F.require(logged.components(separatedBy:" - "+repo.root.path).count==2 && logged.components(separatedBy:"Success").count==2,"Forced retirement did not persist exactly one drained command result")
    }
    @MainActor static func verifyCancellationAndRetry(repo:GitRepository,root:URL,preferences:UserDefaults,clipboard:NSPasteboard)async throws {
        typealias F=FormatPatchWorkflowFixture
        let(slow,marker,release)=try F.wrapper(repo,command:"format-patch"),owner=FormatPatchWindowController(repository:slow,access:nil,preferences:preferences)
        defer{owner.close()};try await configure(owner,directory:root.appendingPathComponent("cancel-output"),clipboard:clipboard,mail:false)
        var alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?,closed=0
        owner.onClosed={closed+=1};owner.presentCancellation={question,parent,reply in alert=question;answer=reply;question.beginSheetModal(for:parent,completionHandler:reply)}
        owner.model.export();try await F.wait("Actual held Format Patch progress missing"){FileManager.default.fileExists(atPath:marker.path) && owner.model.percentage==50 && owner.progressController != nil}
        let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        try F.require(pids.count==2 && pids.allSatisfy{kill($0,0)==0},"Format Patch helper ownership missing")
        owner.model.cancelExport();try await F.wait("Format Patch cancellation question did not attach"){alert?.window.sheetParent===owner.progressController?.window}
        try F.require(alert!.window.defaultButtonCell === (alert!.buttons[0].cell as? NSButtonCell) && alert!.buttons.map{$0.title}==["Yes","No"] && alert!.window.alphaValue==0 && alert!.window.appearance?.name==NSAppearance.Name.darkAqua,"Format Patch kill default/captured appearance differs")
        answer?(.alertSecondButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Format Patch No did not detach actual question"){!owner.model.confirmingCancellation && owner.cancellationAlert==nil}
        try F.require(!owner.model.cancelRequested && pids.allSatisfy{kill($0,0)==0},"Late duplicate Yes killed declined worker")
        owner.model.cancelExport();try await F.wait("Second Format Patch kill question missing"){owner.cancellationAlert != nil}
        owner.model.confirmingQuit=true;owner.model.confirmingQuit=false;answer?(.alertFirstButtonReturn)
        try await F.wait("Stale Quit answer did not detach"){!owner.model.confirmingCancellation && owner.cancellationAlert==nil}
        try F.require(!owner.model.cancelRequested && pids.allSatisfy{kill($0,0)==0},"Pre-Quit kill answer cancelled worker after Quit roundtrip")
        owner.model.cancelExport();try await F.wait("Accepted Format Patch kill question missing"){owner.cancellationAlert != nil};answer?(.alertFirstButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Format Patch cancellation did not reap actual process"){!owner.model.busy && !owner.model.hasPendingWork && owner.model.cancelled && pids.allSatisfy{kill($0,0) != 0}}
        try await F.output(owner.progressController!.window,text:owner.model.output,range:owner.model.completionRange,percentage:owner.model.percentage,success:false,preferences:preferences,clipboard:clipboard)
        owner.model.finish();try await F.wait("Failed progress did not return to actual options after detach"){owner.progressController==nil && !owner.model.progress && !owner.model.finishScheduled && owner.window?.attachedSheet==nil}
        try Data().write(to:release);owner.model.directory=root.appendingPathComponent("retry-output").path;owner.model.mode = .number;owner.model.count=1;owner.model.sendMail=false
        owner.model.export();try F.require(owner.model.hasPendingWork && !owner.model.commandFinished && owner.model.completionRange==nil,"Fresh export Retry retained old receipt")
        try await F.wait("Format Patch retry did not create patches"){!owner.model.busy && !owner.model.hasPendingWork && owner.model.success}
        owner.model.finish();try await F.wait("Successful retry did not close actual options once"){closed==1 && owner.progressController==nil && owner.window?.attachedSheet==nil}
    }
    @MainActor static func verifyQuitEpoch(repo:GitRepository,root:URL,preferences:UserDefaults,clipboard:NSPasteboard)async throws {
        typealias F=FormatPatchWorkflowFixture
        let owner=FormatPatchWindowController(repository:repo,access:nil,preferences:preferences)
        defer{owner.close()};try await configure(owner,directory:root.appendingPathComponent("quit-finish"),clipboard:clipboard,mail:true)
        var mail=0;owner.model.composeMail={_ in mail+=1}
        owner.model.export();try await F.wait("Quit epoch export did not settle"){!owner.model.busy && !owner.model.hasPendingWork && owner.model.success}
        owner.model.finish();owner.model.confirmingQuit=true;owner.model.confirmingQuit=false
        try await F.wait("Quit-stale progress finish did not drain"){owner.progressController==nil && !owner.model.finishScheduled}
        try F.require(mail==0 && !owner.model.composingMail,"Pre-Quit finish opened stale mail after Quit roundtrip")
        owner.close()
        let forced=FormatPatchWindowController(repository:repo,access:nil,preferences:preferences)
        defer{forced.close()};try await configure(forced,directory:root.appendingPathComponent("forced-finish"),clipboard:clipboard,mail:true)
        var forcedMail=0,closed=0;forced.model.composeMail={_ in forcedMail+=1};forced.onClosed={closed+=1}
        forced.model.export();try await F.wait("Forced-finish export did not settle"){!forced.model.busy && !forced.model.hasPendingWork && forced.model.success}
        let progress=forced.progressController!,blocker=F.parent();F.attach(blocker,to:progress.window!)
        forced.model.finish();try F.require(forced.model.finishScheduled && forcedMail==0,"Finish bypassed actual nested progress sheet")
        progress.close();try F.require(forcedMail==0 && closed==0,"Forced progress close dispatched pending mail before native detach")
        progress.window?.endSheet(blocker,returnCode:.abort);blocker.close()
        try await F.wait("Forced progress/options did not drain nested sheet"){closed==1 && forced.progressController==nil && forced.window?.attachedSheet==nil}
        try F.require(forcedMail==0,"Forced progress closure executed queued mail")
    }
    @MainActor static func verifyHeldPicker(repo:GitRepository,root:URL,preferences:UserDefaults,clipboard:NSPasteboard)async throws {
        typealias F=FormatPatchWorkflowFixture
        let helper=root.appendingPathComponent("held-picker-git"),marker=URL(fileURLWithPath:helper.path+".started")
        let script="""
        #!/bin/sh
        held_read() {
          if [ "${1-}" = --literal-pathspecs ] || [ "${1-}" = --no-literal-pathspecs ]; then shift; fi
          if [ "${1-}" = -C ]; then shift 2; fi
          test "${1-}" = rev-parse && test "${2-}" = --is-bare-repository
        }
        if held_read "$@";then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null;wait "$task_child" 2>/dev/null;/bin/sleep 0.2;exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started.tmp";/bin/mv "$0.started.tmp" "$0.started"
          wait "$task_child"
        fi
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let wrapped=GitRepository(root:repo.root,executable:helper),owner=FormatPatchWindowController(repository:repo,access:nil,preferences:preferences)
        defer{owner.close()};try await configure(owner,directory:root.appendingPathComponent("picker-output"),clipboard:clipboard,mail:false)
        owner.model.mode = .from;owner.model.from="HEAD~1";owner.model.to="HEAD"
        owner.makeLogPicker={_,access,revision,prefs,choose in LogWindowController(repository:wrapped,access:access,onChoose:choose,labelDefaults:prefs,initialRevision:revision)}
        var closed=0;owner.onClosed={closed+=1};owner.chooseRevision(.from)
        try await F.wait("Actual Format Patch Log picker did not hold metadata read"){FileManager.default.fileExists(atPath:marker.path) && owner.picker?.model.pendingHistoryLoads==1 && owner.window?.attachedSheet===owner.picker?.window}
        let picker=owner.picker!,pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        try F.require(pids.count==2 && pids.allSatisfy{kill($0,0)==0},"Held picker process registry missing")
        owner.close();try F.require(closed==0 && picker.model.pendingHistoryLoads>0,"Format Patch closed before actual retired picker read drained")
        try await F.wait("Retired Format Patch Log read/sheet did not drain"){closed==1 && picker.model.pendingHistoryLoads==0 && picker.window?.sheetParent==nil && owner.window?.attachedSheet==nil && pids.allSatisfy{kill($0,0) != 0}}
    }

}
