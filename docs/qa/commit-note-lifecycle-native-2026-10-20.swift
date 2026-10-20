// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum CommitNoteLifecycleVerification {
    struct Failure:Error,CustomStringConvertible,LocalizedError {let description:String;var errorDescription:String?{description}}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"\(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Edit Notes timeout at \(line)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func button(_ title:String,in window:NSWindow?)throws->NSButton {
        guard let value=views(window?.contentView).compactMap({$0 as? NSButton}).first(where:{$0.title==title}) else{throw Failure(description:"Missing native button: "+title)};return value
    }
    static func drained()->Bool {HistoryNotesWindowModel.activeReads==0 && HistoryNotesWindowModel.activeMutations==0 && LogWindowModel.activeNoteReads==0 && LogWindowModel.activeNoteSaves==0 && InputWindowController.activeSaves==0 && SettingsTransaction.activeApplications==0 && SynchronizationWindowModel.activeInlineOperations==0 && CommitNotePresenter.activeWarnings==0}
    @MainActor final class Gate<Value> {
        var token:OperationCancellation?,entered=false
        private var continuation:CheckedContinuation<Value,Error>?,result:Result<Value,Error>?
        func read(_ token:OperationCancellation)async throws->Value {
            self.token=token;entered=true
            if let result{return try result.get()}
            return try await withCheckedThrowingContinuation{continuation=$0}
        }
        func finish(_ value:Result<Value,Error>) {guard result==nil else{return};result=value;let reply=continuation;continuation=nil;reply?.resume(with:value)}
    }
    @MainActor final class Context {
        struct Baseline {let repo:GitRepository,head:Data,index:Data,working:Data}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite:String,prefs:UserDefaults
        var syncModels:[SynchronizationWindowModel]=[]
        var notes:[HistoryNotesWindowController]=[],logs:[LogWindowController]=[],unblock:[()->Void]=[],baselines:[Baseline]=[]
        init(){let name="TurtleGit.NoteLifecycle."+UUID().uuidString;suite=name;prefs=UserDefaults(suiteName:name)!;prefs.set("Menlo",forKey:"LogFontName");prefs.set(15,forKey:"LogFontSize");prefs.set(false,forKey:"EnableGravatar");prefs.set(true,forKey:"HintHierarchicalConfig")}
        func fixture(_ name:String)async throws->GitRepository {
            let directory=root.appendingPathComponent(name,isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let repo=GitRepository(root:directory,executable:git,askpass:nil)
            _=try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Notes lifecycle QA"),("user.email","notes@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.logminsize","3"),("tgit.projectlanguage","-1")] {_=try await repo.run(["config",key,value])}
            try Data("unchanged working file\n".utf8).write(to:directory.appendingPathComponent("tracked.txt"));try await repo.stage(["tracked.txt"]);_=try await repo.commit(message:"First note target")
            _=try await repo.run(["commit","--allow-empty","-m","Second note target"])
            baselines.append(.init(repo:repo,head:try await repo.run(["rev-parse","HEAD"]).stdout,index:try Data(contentsOf:directory.appendingPathComponent(".git/index")),working:try Data(contentsOf:directory.appendingPathComponent("tracked.txt"))))
            return repo
        }
        func invisible(_ window:NSWindow?) {window?.alphaValue=0;window?.setFrameOrigin(.init(x:-12000,y:-12000));window?.orderFront(nil)}
        func owner(_ repo:GitRepository,revision:String) -> HistoryNotesWindowController {
            let owner=HistoryNotesWindowController(repository:repo,access:nil,revision:revision,preferences:prefs);notes.append(owner);invisible(owner.window);return owner
        }
        func logOwner(_ repo:GitRepository)->LogWindowController {
            let owner=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,loadsImmediately:false);logs.append(owner);invisible(owner.window);return owner
        }
        func cleanup()async {
            unblock.forEach{$0()};unblock=[];syncModels.forEach{$0.invalidate()};logs.forEach{$0.close()};notes.forEach{$0.close()}
            for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            logs.forEach{$0.window?.orderOut(nil)};notes.forEach{$0.window?.orderOut(nil)};prefs.removePersistentDomain(forName:suite);prefs.synchronize()
        }
        func unchanged()async throws {
            for baseline in baselines {
                let head=try await baseline.repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:baseline.repo.root.appendingPathComponent(".git/index")),working=try Data(contentsOf:baseline.repo.root.appendingPathComponent("tracked.txt"))
                try require(head==baseline.head && index==baseline.index && working==baseline.working,"Notes changed HEAD, index or working files")
            }
        }
    }
    static func run(_ body:(Context)async throws->Void)async throws {
        let context=Context()
        do {try await body(context);try await context.unchanged();await context.cleanup();try require(drained(),"Edit Notes workers failed to drain")}
        catch {await context.cleanup();throw error}
    }
    static func load(_ owner:HistoryNotesWindowController)async throws {owner.model.load();try await wait{!owner.model.loading && owner.model.snapshot != nil && !owner.identitySession.hasPendingWork}}
    static func draft(_ text:String,in editor:InputWindowController) {editor.editor.string=text;editor.textDidChange(Notification(name:NSText.didChangeNotification))}
    static func ref(_ repo:GitRepository,_ name:String)async throws->String? {
        let result=try await repo.run(["rev-parse","--verify","--quiet","--end-of-options",name],successfulExitCodes:0...1)
        return result.exitCode==0 ? result.text.trimmingCharacters(in:.newlines):nil
    }
    static func rawNote(_ repo:GitRepository,revision:String,reference:String)async throws->String? {
        let result=try await repo.run(["notes","--ref="+reference,"list",revision],successfulExitCodes:0...1)
        let blob=result.text.trimmingCharacters(in:.newlines)
        guard result.exitCode==0,!blob.isEmpty else{return nil}
        return try await repo.run(["cat-file","blob",blob]).text
    }
    static func captures(_ window:NSWindow?,stem:String)async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_NOTE_CAPTURE_DIR"] else{return}
        guard let window,let view=window.contentView?.superview ?? window.contentView else{throw Failure(description:"Missing offscreen Notes capture view")}
        let original=window.appearance;defer{window.appearance=original}
        for (suffix,name) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
            window.appearance=NSAppearance(named:name);view.needsDisplay=true
            for _ in 0..<4 {view.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:10_000_000)}
            guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw Failure(description:"Cannot allocate Notes bitmap")}
            view.cacheDisplay(in:view.bounds,to:bitmap)
            guard let png=bitmap.representation(using:.png,properties:[:]) else{throw Failure(description:"Cannot encode Notes bitmap")}
            try png.write(to:URL(fileURLWithPath:path).appendingPathComponent(stem+"-"+suffix+".png"),options:.atomic)
        }
    }
    static func identity()async throws {try await run{context in
        let repo=try await context.fixture("identity"),revision=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        for key in ["user.name","user.email"] {_=try await repo.run(["config","--unset-all",key])}
        let denied=context.owner(repo,revision:revision);var deniedReads=0
        denied.model.read={token in deniedReads += 1;return(try await repo.editableCommitNote(revision:revision,cancellation:token),try await repo.projectDialogSettings(source:.effective,cancellation:token))}
        denied.model.load();try await wait{denied.identitySession.question != nil}
        try require(deniedReads==0 && denied.model.snapshot==nil && !denied.canAccept,"Missing identity loaded Notes before source repair")
        denied.identitySession.question!.buttons[1].performClick(nil);try await wait{!denied.model.loading && !denied.identitySession.hasPendingWork}
        let deniedRef=try await ref(repo,"refs/notes/commits")
        try require(deniedReads==0 && deniedRef==nil,"Identity No created/read a note")
        let owner=context.owner(repo,revision:revision);var reads=0
        owner.model.read={token in reads += 1;return(try await repo.editableCommitNote(revision:revision,cancellation:token),try await repo.projectDialogSettings(source:.effective,cancellation:token))}
        owner.model.load();try await wait{owner.identitySession.question != nil}
        try await captures(owner.identitySession.question?.window,stem:"notes-identity")
        let first=owner.identitySession.question!;first.buttons[0].performClick(nil)
        try await wait{owner.identitySession.settingsWindow != nil}
        try require(owner.identitySession.navigation?.selected == .git && reads==0,"Notes repair lost captured Git Settings/source ordering")
        try button("Cancel",in:owner.identitySession.settingsWindow).performClick(nil)
        try await wait{owner.identitySession.question != nil && owner.identitySession.question !== first}
        try require(reads==0 && owner.model.snapshot==nil,"Settings Cancel certified missing identity")
        owner.identitySession.question!.buttons[0].performClick(nil);try await wait{owner.identitySession.settingsWindow != nil}
        for (key,value) in [("user.name","Repaired note author"),("user.email","repair@example.invalid"),("core.notesRef","refs/notes/repaired")] {_=try await repo.run(["config",key,value])}
        try button("Cancel",in:owner.identitySession.settingsWindow).performClick(nil)
        try await wait{!owner.model.loading && owner.model.snapshot != nil && !owner.identitySession.hasPendingWork}
        try require(reads==1 && owner.model.snapshot?.notesRef=="refs/notes/repaired" && owner.editor.font?.fontName=="Menlo-Regular","Identity repair did not reread configuration/use captured editor preferences")
        draft("Identity repaired note",in:owner);owner.save();try await wait{owner.saved && HistoryNotesWindowModel.activeMutations==0 && InputWindowController.activeSaves==0}
        try require((try await rawNote(repo,revision:revision,reference:"refs/notes/repaired"))=="Identity repaired note","Repaired Notes save used obsolete note ref")
        let retry=context.owner(repo,revision:revision);var attempts=0
        retry.identitySession.readIdentity={token in attempts += 1;if attempts==1{throw Failure(description:"Injected identity read failure")};return try await repo.replayUserIdentity(cancellation:token)}
        retry.model.load();try await wait{!retry.model.loading && retry.errorLabel.stringValue.contains("identity read failure")}
        try require(retry.model.snapshot==nil && !retry.canAccept && retry.ok.title=="Retry" && retry.ok.isEnabled,"Identity read failure exposed an unprepared editor or lost Retry")
        retry.ok.performClick(nil);try await wait{!retry.model.loading && retry.model.snapshot != nil}
        try require(attempts==2 && retry.editor.string=="Identity repaired note","Identity Retry did not reread authoritative note/configuration")
    }}
    static func retry()async throws {try await run{context in
        let repo=try await context.fixture("retry"),revision=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),owner=context.owner(repo,revision:revision)
        try await load(owner)
        var calls=0
        owner.model.writeNote={note,text,token in calls += 1;if calls==1 {throw Failure(description:"Injected recoverable note failure")};return try await repo.saveCommitNote(note,text:text,cancellation:token)}
        guard let undo=owner.editor.undoManager else{throw Failure(description:"Notes editor lacks native Undo")}
        undo.removeAllActions();owner.editor.breakUndoCoalescing();owner.editor.insertText("Keep this complete draft 雪",replacementRange:NSRange(location:0,length:(owner.editor.string as NSString).length));owner.editor.breakUndoCoalescing()
        try require(undo.canUndo,"Native Notes edit failed to establish Undo")
        owner.save();try await wait{!owner.busy && owner.errorLabel.stringValue.contains("recoverable")}
        let failedRef=try await ref(repo,"refs/notes/commits")
        try require(calls==1 && owner.editor.string=="Keep this complete draft 雪" && owner.canAccept && !owner.saved && failedRef==nil,"Failed note save lost draft/retry or changed ref")
        try require(undo.canUndo,"Failed Notes save cleared native Undo")
        undo.undo();try await wait{owner.editor.string.isEmpty};undo.redo();try await wait{owner.editor.string=="Keep this complete draft 雪"}
        owner.save();try await wait{InputWindowController.activeSaves==0 && HistoryNotesWindowModel.activeMutations==0}
        let retried=try await rawNote(repo,revision:revision,reference:"refs/notes/commits")
        try require(calls==2 && retried=="Keep this complete draft 雪","Retry did not save exactly the retained draft")
        let uncertain=context.owner(repo,revision:revision);try await load(uncertain)
        uncertain.model.writeNote={note,text,token in _=try await repo.saveCommitNote(note,text:text,cancellation:token);throw CommitNoteFailure.saveOutcomeUnknown("Injected lost result receipt")}
        draft("Retain uncertain result draft",in:uncertain);uncertain.save();try await wait{!uncertain.busy && InputWindowController.activeSaves==0}
        let uncertainText=try await rawNote(repo,revision:revision,reference:"refs/notes/commits")
        try require(!uncertain.saved && uncertain.canAccept && uncertain.editor.string=="Retain uncertain result draft" && uncertain.errorLabel.stringValue.contains("may have been saved") && uncertainText==uncertain.editor.string,"Uncertain result was falsely accepted/discarded or misreported actual ref outcome")
        let known=context.owner(repo,revision:revision);try await load(known)
        known.model.writeNote={note,text,token in _=try await repo.saveCommitNote(note,text:text,cancellation:token);throw CommitNoteFailure.savedButRefreshFailed("Injected display refresh failure")}
        draft("Known saved despite refresh failure",in:known);known.save();try await wait{known.saved && InputWindowController.activeSaves==0}
        let knownText=try await rawNote(repo,revision:revision,reference:"refs/notes/commits")
        try require(knownText=="Known saved despite refresh failure" && known.model.error?.contains("Notes saved")==true,"Known saved result lost truthful outcome after refresh failure")
        // Exercise the Sync consumer with the definitive warning produced by
        // that real write. Its asynchronous refresh must not erase the result,
        // including when refreshing the selected local revision itself fails.
        let sync=SynchronizationWindowModel(repository:repo,access:nil,preferences:context.prefs);context.syncModels.append(sync)
        sync.localBranch="invalid\0note-refresh-target"
        let warning=known.model.error!
        sync.finishNoteEditing(warning:warning)
        try require(sync.historyNoteWarning==warning,"Sync did not retain the completed note warning when refresh started")
        try await wait{!sync.busy && SynchronizationWindowModel.activeInlineOperations==0}
        try require(sync.historyNoteWarning==warning && sync.status.contains(warning),"Sync async refresh erased definitive saved-note warning")
        guard let refreshError=sync.error else{throw Failure(description:"Sync invalid refresh fixture did not fail")}
        try require(sync.status.contains(warning) && sync.status.contains(refreshError),"Sync refresh error hid the definitive saved-note warning")
        sync.refresh();try require(sync.historyNoteWarning==nil,"Explicit Sync refresh did not clear the acknowledged note warning")
        try await wait{!sync.busy && SynchronizationWindowModel.activeInlineOperations==0}
        let log=context.logOwner(repo);log.model.reload();try await wait{!log.model.busy && log.model.entries.contains(where:{$0.hash==revision})};log.model.selected=[revision]
        var reloads=0
        log.model.onRevisionChanged={ [weak model=log.model] _ in reloads += 1;model?.reload() }
        log.model.writeNote={note,text,token in _=try await repo.saveCommitNote(note,text:text,cancellation:token);throw CommitNoteFailure.savedButRefreshFailed("Actual Log completion warning fixture")}
        log.model.editNotes();try await wait{log.noteEditor != nil};let logEditor=log.noteEditor!
        draft("Log note saved with persistent completion warning",in:logEditor);logEditor.save()
        try await wait{log.noteEditor==nil && log.model.noteWarningPending && log.window?.attachedSheet != nil && !log.model.busy && reloads==1}
        let warningSheet=log.window!.attachedSheet!,labels=views(warningSheet.contentView).compactMap{($0 as? NSTextField)?.stringValue}.joined(separator:"\n")
        let logText=try await rawNote(repo,revision:revision,reference:"refs/notes/commits")
        try require(logEditor.saved && logText=="Log note saved with persistent completion warning" && labels.contains("Notes saved") && labels.contains("Actual Log completion warning fixture") && log.model.noteCompletionWarning?.contains("Notes saved")==true && !log.model.canEditNotes && CommitNotePresenter.activeWarnings==1,"Log reload lost definitive saved result/actual owned warning sheet or its command gate")
        try button("OK",in:warningSheet).performClick(nil)
        try await wait{!log.model.noteWarningPending && CommitNotePresenter.activeWarnings==0 && log.window?.attachedSheet==nil}
        try require(log.model.noteCompletionWarning==nil,"Acknowledged Log completion warning retained stale pending detail")
    }}
    static func cancellation()async throws {try await run{context in
        let repo=try await context.fixture("cancellation"),revision=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let owner=context.owner(repo,revision:revision);try await load(owner)
        let before=Gate<String>();context.unblock.append{before.finish(.failure(OperationCancellationFailure.cancelled))}
        var calls=0
        owner.model.writeNote={_,_,token in calls += 1;return try await before.read(token)}
        draft("Cancel before mutation; retain complete draft",in:owner);owner.save();try await wait{before.entered}
        owner.cancelButton.performClick(nil)
        try require(before.token?.isCancelled==true && owner.busy && owner.cancelling && !owner.saved && InputWindowController.activeSaves==1 && HistoryNotesWindowModel.activeMutations==1,"Cancellation released an unretired save or failed to cancel its shared token")
        before.finish(.failure(OperationCancellationFailure.cancelled));try await wait{!owner.busy && InputWindowController.activeSaves==0 && HistoryNotesWindowModel.activeMutations==0}
        let absent=try await ref(repo,"refs/notes/commits")
        try require(absent==nil && calls==1 && owner.canAccept && owner.editor.string=="Cancel before mutation; retain complete draft" && !owner.saved,"Cancelled pre-write save mutated ref/lost retry draft")
        // A cancellation arriving after a proven write must report the actual
        // successful outcome; it cannot promise that Cancel undid Git's update.
        let receipt=Gate<String>();context.unblock.append{receipt.finish(.failure(OperationCancellationFailure.cancelled))}
        owner.model.writeNote={note,text,token in calls += 1;let display=try await repo.saveCommitNote(note,text:text,cancellation:token);_ = try await receipt.read(token);return display}
        owner.save();try await wait{receipt.entered}
        let committed=try await rawNote(repo,revision:revision,reference:"refs/notes/commits")
        try require(committed==owner.editor.string,"Held save receipt did not follow a real notes ref update")
        owner.cancel();try require(receipt.token?.isCancelled==true && owner.busy && InputWindowController.activeSaves==1,"Post-write Cancel lost pending receipt accounting")
        receipt.finish(.success("release known successful receipt"));try await wait{owner.saved && InputWindowController.activeSaves==0 && HistoryNotesWindowModel.activeMutations==0}
        let final=try await rawNote(repo,revision:revision,reference:"refs/notes/commits")
        try require(calls==2 && final==committed,"Post-write cancellation retried/undid a proven save")
    }}
    static func ownership()async throws {try await run{context in
        let repo=try await context.fixture("ownership"),revision=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let late=context.owner(repo,revision:revision),identity=Gate<ReplayUserIdentity>()
        context.unblock.append{identity.finish(.failure(OperationCancellationFailure.cancelled))}
        var closed=false;late.onClosed={closed=true};late.identitySession.readIdentity={token in try await identity.read(token)}
        late.model.load();try await wait{identity.entered};late.window!.close()
        try require(identity.token?.isCancelled==true && !closed && HistoryNotesWindowModel.activeReads==1 && late.identitySession.hasPendingWork,"Owner close released pending identity work or missed cancellation")
        identity.finish(.success(try await repo.replayUserIdentity()));try await wait{closed && HistoryNotesWindowModel.activeReads==0 && !late.identitySession.hasPendingWork}
        try require(late.model.invalidated && late.model.snapshot==nil && late.identitySession.question==nil && late.identitySession.settingsWindow==nil,"Late identity receipt reopened retired Notes")
        for key in ["user.name","user.email"] {_=try await repo.run(["config","--unset-all",key])}
        let repair=context.owner(repo,revision:revision);repair.model.load();try await wait{repair.identitySession.question != nil}
        repair.identitySession.question!.buttons[0].performClick(nil);try await wait{repair.identitySession.settingsWindow != nil}
        let settings=repair.identitySession.settingsWindow!;var repairClosed=false;repair.onClosed={repairClosed=true};repair.window!.close()
        try await wait{repairClosed && !repair.identitySession.hasPendingWork && HistoryNotesWindowModel.activeReads==0 && settings.sheetParent==nil}
        try require(repair.model.invalidated && repair.model.snapshot==nil && repair.identitySession.settingsWindow==nil,"Forced Notes owner close retained/reopened Git Settings")
        for (key,value) in [("user.name","Restored author"),("user.email","restored@example.invalid")] {_=try await repo.run(["config",key,value])}
        let owner=context.logOwner(repo);owner.model.reload();try await wait{!owner.model.busy && owner.model.entries.count>=2};owner.model.selected=[revision]
        owner.model.editNotes();try await wait{owner.noteEditor != nil}
        let editor=owner.noteEditor!,write=Gate<String>();context.unblock.append{write.finish(.failure(OperationCancellationFailure.cancelled))}
        owner.model.writeNote={_,_,token in try await write.read(token)}
        draft("Closed Log owner must retain pending save",in:editor);editor.save();try await wait{write.entered}
        var parentClosed=false;owner.onClosed={parentClosed=true};owner.window!.close()
        try require(write.token?.isCancelled==true && !parentClosed && LogWindowModel.activeNoteSaves==1 && InputWindowController.activeSaves==1,"Closed Log owner lost child save/Quit drain accounting")
        write.finish(.failure(OperationCancellationFailure.cancelled));try await wait{parentClosed && LogWindowModel.activeNoteSaves==0 && InputWindowController.activeSaves==0}
        let untouched=try await ref(repo,"refs/notes/commits")
        try require(owner.model.isInvalidated && owner.noteEditor==nil && untouched==nil && !editor.saved,"Retired save changed Notes/reopened child")
    }}
    static func target()async throws {try await run{context in
        let repo=try await context.fixture("target"),owner=context.logOwner(repo)
        owner.model.reload();try await wait{!owner.model.busy && owner.model.entries.count>=2}
        let chosen=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),other=try await repo.run(["rev-parse","HEAD^"]).text.trimmingCharacters(in:.newlines)
        try require(owner.model.entries.contains(where:{$0.hash==chosen}) && owner.model.entries.contains(where:{$0.hash==other}),"Log did not load both actual commit targets")
        _=try await repo.run(["config","core.notesRef","refs/notes/original"])
        owner.model.selected=[chosen];owner.model.editNotes();try await wait{owner.noteEditor != nil}
        let editor=owner.noteEditor!
        try require(editor.window?.sheetParent === owner.window && editor.editor.font?.pointSize==15,"Notes editor lost native owner or captured font")
        draft("ab",in:editor);editor.save();try require(!editor.busy && !editor.canAccept,"Notes accepted a draft shorter than source project minimum")
        draft("Captured target/ref note\nComplete draft 雪",in:editor)
        try await captures(editor.window,stem:"notes-editor")
        owner.model.selected=[other];_=try await repo.run(["config","core.notesRef","refs/notes/later"])
        editor.save();try await wait{owner.noteEditor==nil && !owner.model.savingNote && InputWindowController.activeSaves==0}
        let intended=try await rawNote(repo,revision:chosen,reference:"refs/notes/original"),wrongRevision=try await rawNote(repo,revision:other,reference:"refs/notes/original"),wrongRef=try await ref(repo,"refs/notes/later")
        try require(editor.saved && intended=="Captured target/ref note\nComplete draft 雪" && wrongRevision==nil && wrongRef==nil,"Notes followed live selection/configuration instead of captured revision/ref")
        owner.model.editNotes();try await wait{owner.noteEditor != nil};let discarded=owner.noteEditor!
        draft("Discard this draft",in:discarded);discarded.cancel();try await wait{owner.noteEditor==nil}
        let cancelledRef=try await ref(repo,"refs/notes/later")
        try require(!discarded.saved && cancelledRef==nil,"Idle Notes Cancel saved a draft")
    }}
}
