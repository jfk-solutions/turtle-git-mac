import AppKit
import Darwin
import ScreenCaptureKit
import TurtleGitCore

@main struct CommitVisibilityVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String) throws {if !condition {throw Failure(description:message)}}
    static func trace(_ phase:String) { fputs("Commit visibility phase: \(phase)\n",stderr);fflush(stderr) }
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Commit visibility timeout at \(line)")
    }
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func capture(_ window:NSWindow,prefix:String) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_COMMIT_VISIBILITY_CAPTURE"] else{return}
        guard #available(macOS 14.4,*) else {throw Failure(description:"Owned capture unavailable")}
        let alpha=window.alphaValue,appearance=window.appearance
        window.alphaValue=1;window.orderFront(nil);defer{window.alphaValue=alpha;window.appearance=appearance}
        for (theme,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned visibility capture absent")}
            let options=SCStreamConfiguration();options.width=Int(window.frame.width*2);options.height=Int(window.frame.height*2);options.showsCursor=false;options.ignoreShadowsSingleWindow=true;options.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:options)
            guard let data=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure(description:"Visibility PNG encoding failed")}
            try data.write(to:URL(fileURLWithPath:folder).appendingPathComponent(prefix+"-"+name+".png"))
        }
    }
    @MainActor static func main() async {do{try await verify()}catch{fputs("Commit visibility failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Visibility QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","false")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("tracked"));try await repo.stage(["tracked"]);_ = try await repo.commit(message:"base")
        try Data("private unversioned\n".utf8).write(to:root.appendingPathComponent("new.txt"))
        let originalHead=try await repo.run(["rev-parse","HEAD"]).stdout,originalIndex=try await repo.run(["ls-files","--stage","-z"]).stdout
        let suite="TurtleGit.CommitVisibility."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"AddBeforeCommit");prefs.set(true,forKey:"HintStagingMode");prefs.set(true,forKey:"Commit.SkipCancelConfirmation");prefs.set(false,forKey:"EnableGravatar")
        defer{prefs.removePersistentDomain(forName:suite)}
        var owners:[CommitWindowController]=[];defer{owners.forEach{$0.close()}}
        func make(visible:Bool=true)->CommitWindowController {
            let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs);owners.append(owner);owner.window?.alphaValue=0
            if visible {owner.window?.orderFront(nil)}
            return owner
        }
        func settled(_ model:CommitWindowModel) async throws {try await wait {!model.busy && !model.savingPreferences && !model.stagingHintVisible && !model.unversionedPromptVisible}}
        func prompted(_ owner:CommitWindowController) async throws -> NSAlert {
            try await wait {owner.unversionedFilesAlert != nil && owner.model.unversionedPromptVisible}
            guard let alert=owner.unversionedFilesAlert else {throw Failure(description:"Owned prompt disappeared")}
            alert.window.alphaValue=0;return alert
        }
        trace("hidden files and native Yes/No sheets")
        // Invisible owners defer the actual sheet, then retry when presented.
        let owner=make(visible:false),model=owner.model;model.reload();try await settled(model)
        try require(owner.unversionedFilesAlert==nil && !model.showUnversioned && model.visibleEntries.isEmpty,"Invisible owner showed/revealed hidden files")
        owner.window?.orderFront(nil);model.offerUnversionedFiles();let first=try await prompted(owner)
        try require(first.messageText==CommitWindowModel.noChangesMessage && first.informativeText=="Do you want to see the unversioned files?" && first.buttons.map(\.title)==["Yes","No"] && first.suppressionButton != nil,"Source hidden-file explanation/choices missing")
        try require(model.inputsBlocked && !model.canCommit && !model.canCancel && CommitWindowModel.activePreferenceOperations>0,"Owned prompt did not gate actions/retain lifetime")
        let columns=model.fileColumns,policy=model.doNotAutoselectSubmodules
        model.setShowUnversioned(true);model.setDoNotAutoselectSubmodules(!policy);model.setFileColumn(.status,visible:false);model.savePatchPreference(true);model.reload()
        try require(!model.showUnversioned && model.doNotAutoselectSubmodules==policy && model.fileColumns==columns && !model.busy && !model.savingPreferences,"Prompt allowed delayed controls/reload")
        try await capture(first.window,prefix:"commit-hidden-unversioned")
        first.buttons[1].performClick(nil);try await settled(model)
        try await wait {owner.window?.attachedSheet==nil}
        try require(model.fileListEmptyMessage==CommitWindowModel.noChangesMessage && prefs.object(forKey:"NothingToCommitShowUnversioned")==nil && !prefs.bool(forKey:"AddBeforeCommit"),"Unsuppressed No changed settings/source empty text")
        model.offerUnversionedFiles();try require(!model.unversionedPromptVisible,"Unsuppressed No repeated without refresh")
        try await capture(owner.window!,prefix:"commit-empty-changes")
        // F5 offers again. Remembered Yes reveals live rows, leaving global AddBeforeCommit untouched.
        model.reload();let second=try await prompted(owner);second.suppressionButton?.state = .on;second.buttons[0].performClick(nil);try await settled(model)
        try require(model.showUnversioned && model.visibleEntries.contains{$0.path=="new.txt"} && !model.checked.contains("new.txt") && prefs.integer(forKey:"NothingToCommitShowUnversioned")==6 && !prefs.bool(forKey:"AddBeforeCommit"),"Remembered Yes did not preserve source reveal/check/preference semantics")
        let replayYes=make();replayYes.model.reload();try await settled(replayYes.model)
        try require(replayYes.model.showUnversioned && replayYes.unversionedFilesAlert==nil && !prefs.bool(forKey:"AddBeforeCommit"),"Stored IDYES did not bypass sheet/live reveal")
        replayYes.close()
        trace("remembered decisions and selected scopes")
        // Remembered No is a distinct source answer; Stored decisions reset restores asking.
        prefs.set(7,forKey:"NothingToCommitShowUnversioned")
        let replayNo=make();replayNo.model.reload();try await settled(replayNo.model)
        try require(!replayNo.model.showUnversioned && replayNo.unversionedFilesAlert==nil && replayNo.model.visibleEntries.isEmpty,"Stored IDNO did not retain hidden rows")
        SavedDataStore(preferences:prefs).clear(.storedDecisions);prefs.set(true,forKey:"HintStagingMode");prefs.set(true,forKey:"Commit.SkipCancelConfirmation")
        replayNo.model.reload();let cleared=try await prompted(replayNo);cleared.suppressionButton?.state = .on;cleared.buttons[1].performClick(nil);try await settled(replayNo.model)
        try require(prefs.integer(forKey:"NothingToCommitShowUnversioned")==7,"Actual suppressed No did not save IDNO")
        try await wait {replayNo.window?.attachedSheet==nil}
        replayNo.close();prefs.removeObject(forKey:"NothingToCommitShowUnversioned")
        // Scope excludes unrelated loose files; merge state suppresses the offer.
        let scoped=make();scoped.model.reload(paths:["tracked"]);try await settled(scoped.model)
        try require(scoped.unversionedFilesAlert==nil && scoped.model.visibleEntries.isEmpty,"Unversioned paths outside selected scope prompted")
        scoped.close()
        prefs.set(1,forKey:"CommitMergeHint") // This visibility case does not exercise the independent source merge-information sheet.
        let mergeHead=root.appendingPathComponent(".git/MERGE_HEAD");try originalHead.write(to:mergeHead)
        let merge=make();merge.model.reload();try await settled(merge.model)
        try require(merge.model.operation == .merge && merge.unversionedFilesAlert==nil && !merge.model.showUnversioned,"Merge state offered unrelated unversioned files")
        merge.close();try FileManager.default.removeItem(at:mergeHead)
        trace("existing sheet handoff")
        // An existing owner sheet defers the offer; its completion retries on the same owner.
        let deferred=make(),blocker=NSWindow(contentRect:NSRect(x:0,y:0,width:220,height:90),styleMask:[.titled],backing:.buffered,defer:false)
        blocker.isReleasedWhenClosed=false;blocker.alphaValue=0;deferred.window!.beginSheet(blocker,completionHandler:nil);deferred.model.reload();try await settled(deferred.model)
        try require(deferred.unversionedFilesAlert==nil && !deferred.model.showUnversioned,"Visibility prompt displaced an existing owner sheet")
        deferred.window!.endSheet(blocker);blocker.orderOut(nil);let afterSheet=try await prompted(deferred)
        afterSheet.buttons[1].performClick(nil);try await settled(deferred.model)
        try await wait {deferred.window?.attachedSheet==nil}
        deferred.close();blocker.close()
        trace("existing sheet handoff drained")
        trace("forced and noncooperative prompt retirement")
        // Forced native owner close resolves the sheet once without storing its pending choice.
        let closing=make();closing.model.reload();let closingAlert=try await prompted(closing);closingAlert.suppressionButton?.state = .on
        closing.close();try await wait {CommitWindowModel.activePreferenceOperations==0}
        try require(closing.unversionedFilesAlert==nil && closingAlert.window.sheetParent==nil && prefs.object(forKey:"NothingToCommitShowUnversioned")==nil && !closing.model.showUnversioned,"Native close retained/replied to a retired sheet")
        // A noncooperative injected answer retains its worker until return but cannot revive state.
        var response:CheckedContinuation<(show:Bool,remember:Bool)?,Never>?
        let late=make();late.model.presentUnversionedFiles={await withCheckedContinuation {response=$0}};late.model.reload();try await wait {response != nil}
        late.close();try require(CommitWindowModel.activePreferenceOperations>0,"Retirement released an undrained injected response")
        response?.resume(returning:(true,true));response=nil;try await wait {CommitWindowModel.activePreferenceOperations==0}
        try require(!late.model.showUnversioned && !late.model.messageFocusAvailable && late.window?.isVisible==false && prefs.object(forKey:"NothingToCommitShowUnversioned")==nil,"Late answer changed preferences/reopened retired owner")
        trace("status read failure/retry/cancellation")
        // Initial loading/failure, retry and cancellation retain real worker ownership.
        let loading=make();var status:CheckedContinuation<[StatusEntry],Error>?
        loading.model.queryCommitStatus={_,_ in try await withCheckedThrowingContinuation {status=$0}};loading.model.reload();try await wait {status != nil}
        try require(loading.model.fileListEmptyMessage=="Loading changes…\nReading changes…" && loading.model.reloadPhase == .changes && loading.model.busy && CommitWindowModel.activeReloads>0,"Initial held status read did not show its loading and changes phase")
        status?.resume(throwing:Failure(description:"private status failure"));status=nil;try await wait {!loading.model.busy}
        try require(loading.model.fileListReadError != nil && loading.model.fileListEmptyMessage?.contains("Could not load changes.")==true && !loading.model.unversionedPromptVisible,"Read failure claimed a clean tree/offered hidden files")
        loading.model.error=nil;try await wait {loading.window?.attachedSheet==nil}
        loading.model.reload();try await wait {status != nil}
        var cancelled=false;loading.model.cancel(closeWindow:false){cancelled=$0}
        try require(loading.model.fileListEmptyMessage=="Cancelling…" && !cancelled && CommitWindowModel.activeReloads>0,"Read cancellation dropped ownership/confirmation")
        status?.resume(returning:[]);status=nil;try await wait {cancelled && !loading.model.busy}
        try require(loading.model.fileListReadCancelled && loading.model.fileListEmptyMessage=="Refresh cancelled. Press F5 to retry." && !loading.model.unversionedPromptVisible,"Cancelled empty read claimed success")
        loading.model.queryCommitStatus={try await repo.commitDialogStatus(amendToParent:$0,cancellation:$1)}
        loading.model.presentUnversionedFiles={(false,false)};loading.model.reload();try await settled(loading.model)
        try require(loading.model.fileListReadError==nil && !loading.model.fileListReadCancelled && loading.model.fileListEmptyMessage==CommitWindowModel.noChangesMessage,"Retry retained stale failure/cancellation state")
        // Refresh failure preserves an accepted visible snapshot and never turns it into a clean tree.
        loading.model.setShowUnversioned(true);let accepted=loading.model.entries
        loading.model.queryCommitStatus={_,_ in throw Failure(description:"refresh failure")};loading.model.reload();try await wait {!loading.model.busy}
        try require(loading.model.entries==accepted && loading.model.fileListEmptyMessage==nil && loading.model.fileListReadError != nil,"Failed refresh lost accepted rows")
        loading.model.error=nil;loading.close()
        let retiredRead=make();var retiredStatus:CheckedContinuation<[StatusEntry],Never>?
        retiredRead.model.queryCommitStatus={_,_ in await withCheckedContinuation {retiredStatus=$0}};retiredRead.model.reload();try await wait {retiredStatus != nil}
        retiredRead.close();try require(CommitWindowModel.activeReloads>0,"Closed loading owner released an undrained status worker")
        retiredStatus?.resume(returning:StatusEntry.parse(Data("?? late.txt\0".utf8)));retiredStatus=nil;try await wait {CommitWindowModel.activeReloads==0}
        try require(retiredRead.model.entries.isEmpty && retiredRead.model.error==nil && !retiredRead.model.messageFocusAvailable,"Late refresh republished into a retired owner")
        let unchangedHead=try await repo.run(["rev-parse","HEAD"]).stdout,unchangedIndex=try await repo.run(["ls-files","--stage","-z"]).stdout
        try require(unchangedHead==originalHead && unchangedIndex==originalIndex,"Visibility/prompt/settings changed HEAD/index")
        trace("real selected Commit")
        // A real selected commit saves the temporary reveal after its actual attempt.
        prefs.set(false,forKey:"AddBeforeCommit");model.message="add private unversioned file";model.checked=["new.txt"];model.onCommitProgress={$0.dismissWithoutWindow=true};model.commit()
        try await wait {CommitWindowModel.activeCommitPreflights==0 && !model.busy}
        let committed=try await repo.run(["show","HEAD:new.txt"]).stdout
        try require(committed==Data("private unversioned\n".utf8) && prefs.bool(forKey:"AddBeforeCommit") && !model.messageFocusAvailable,"Actual Commit failed to persist temporary reveal")
        trace("author date native controls and source bounds")
        // Source ranges only the calendar control; the time control retains seconds independently.
        let dates=make();dates.model.reload();try await settled(dates.model);dates.model.setAuthorDate=true
        try await wait {views(dates.window?.contentView).compactMap{$0 as? NSDatePicker}.count==2 && !dates.model.loadingAuthorDate}
        let pickers=views(dates.window?.contentView).compactMap{$0 as? NSDatePicker}
        guard let dayPicker=pickers.first(where:{$0.datePickerElements == .yearMonthDay}),let clockPicker=pickers.first(where:{$0.datePickerElements == .hourMinuteSecond}) else {throw Failure(description:"Source date/time controls missing")}
        let calendar=CommitAuthorDateControl.calendar,limits=CommitAuthorDateControl.range()
        try require(dayPicker.minDate==limits.lowerBound && dayPicker.maxDate==limits.upperBound && clockPicker.minDate==nil && clockPicker.maxDate==nil,"Date-only inclusive bounds or independent time differ from source")
        let clock=calendar.date(from:DateComponents(year:2026,month:5,day:10,hour:17,minute:23,second:41))!
        dates.model.authorDate=clock
        for boundary in [limits.lowerBound,limits.upperBound] {
            dates.model.authorDate=CommitAuthorDateControl.merging(day:boundary,time:clock)
            try await wait {dayPicker.dateValue==boundary}
            NSApp.sendAction(dayPicker.action!,to:dayPicker.target,from:dayPicker)
            let components=calendar.dateComponents([.hour,.minute,.second],from:dates.model.authorDate)
            try require(calendar.startOfDay(for:dates.model.authorDate)==boundary && components.hour==17 && components.minute==23 && components.second==41,"Inclusive day selection lost independent clock seconds")
        }
        let nextClock=calendar.date(from:DateComponents(year:2026,month:5,day:10,hour:21,minute:32,second:19))!
        clockPicker.dateValue=nextClock;NSApp.sendAction(clockPicker.action!,to:clockPicker.target,from:clockPicker)
        try require(calendar.startOfDay(for:dates.model.authorDate)==limits.upperBound && calendar.component(.second,from:dates.model.authorDate)==19,"Clock editing changed the last permitted calendar day")
        trace("loaded author metadata bounds")
        // Loading an unsupported author day rejects only the date SetTime, retaining its previous day.
        let metadata=CommitWindowModel(repository:repo,access:nil,unversionedDefaults:prefs,dialogDefaults:prefs)
        metadata.reload();try await wait {!metadata.busy && metadata.commitIdentityPrepared}
        try require(metadata.error==nil,"Metadata date owner initialization failed")
        metadata.amend=true;metadata.setAuthorDate=true;metadata.authorDate=clock
        for raw in [calendar.date(from:DateComponents(year:1969,month:12,day:31,hour:9,minute:8,second:7))!,calendar.date(from:DateComponents(year:2100,month:1,day:1,hour:11,minute:12,second:13))!] {
            metadata.queryCommitAuthorDate={_ in raw};metadata.dateChanged();try await wait {!metadata.loadingAuthorDate}
            try require(calendar.startOfDay(for:metadata.authorDate)==calendar.startOfDay(for:clock) && calendar.dateComponents([.hour,.minute,.second],from:metadata.authorDate)==calendar.dateComponents([.hour,.minute,.second],from:raw),"Out-of-range metadata clamped calendar day/lost loaded clock")
        }
        for raw in [limits.lowerBound,limits.upperBound] {
            metadata.queryCommitAuthorDate={_ in raw};metadata.dateChanged();try await wait {!metadata.loadingAuthorDate};try require(metadata.authorDate==raw,"Source inclusive programmatic date endpoint rejected")
        }
        metadata.invalidateForClose()
        dates.model.messageOnly=true;dates.model.message="invalid override must not commit";dates.model.authorDate=Date(timeIntervalSince1970:-1)
        try require(dates.model.canCommit,"Invalid-date fixture was not otherwise ready")
        dates.model.commit();try require(dates.model.error=="Invalid time" && CommitWindowModel.activeCommitPreflights==0,"Pre-epoch explicit override entered Commit work")
        dates.model.error=nil;dates.close()
        trace("native author/date callback ownership")
        let callbacks=make();callbacks.model.reload();try await settled(callbacks.model)
        callbacks.model.setAuthor=true;callbacks.model.setAuthorDate=true
        try await wait {!callbacks.model.loadingAuthorIdentity && !callbacks.model.loadingAuthorDate && views(callbacks.window?.contentView).compactMap{$0 as? NSDatePicker}.count==2}
        guard let identity=views(callbacks.window?.contentView).compactMap({$0 as? NSTextField}).first(where:{$0.accessibilityLabel()=="Author identity"}),
              let identityCallback=identity.delegate as? CommitAuthorField.Coordinator,
              let obsoleteDay=views(callbacks.window?.contentView).compactMap({$0 as? NSDatePicker}).first(where:{$0.datePickerElements == .yearMonthDay}),
              let obsoleteTarget=obsoleteDay.target,let obsoleteAction=obsoleteDay.action else {throw Failure(description:"Author/date callback fixture has no native target")}
        try await wait {identity.isEditable && callbacks.model.nativeAuthorInputAvailable && callbacks.model.nativeAuthorDateInputAvailable}
        let acceptedAuthor=callbacks.model.author,acceptedDate=callbacks.model.authorDate
        callbacks.model.confirmingQuit=true
        identity.stringValue="blocked <quit@example.invalid>";identityCallback.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:identity))
        obsoleteDay.dateValue=limits.lowerBound;NSApp.sendAction(obsoleteAction,to:obsoleteTarget,from:obsoleteDay)
        try require(callbacks.model.author==acceptedAuthor && callbacks.model.authorDate==acceptedDate,"Queued author/date callback bypassed Quit without waiting for SwiftUI disable")
        callbacks.model.confirmingQuit=false;callbacks.model.busy=true
        identityCallback.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:identity));NSApp.sendAction(obsoleteAction,to:obsoleteTarget,from:obsoleteDay)
        try require(callbacks.model.author==acceptedAuthor && callbacks.model.authorDate==acceptedDate,"Queued author/date callback bypassed operation ownership")
        callbacks.model.busy=false;callbacks.model.setAuthorDate=false
        try await wait {obsoleteDay.target==nil && obsoleteDay.action==nil}
        callbacks.model.setAuthorDate=true
        try await wait {!callbacks.model.loadingAuthorDate && callbacks.model.nativeAuthorDateInputAvailable && views(callbacks.window?.contentView).compactMap{$0 as? NSDatePicker}.count==2}
        let replacementDate=callbacks.model.authorDate
        obsoleteDay.isEnabled=true;obsoleteDay.dateValue=limits.lowerBound
        NSApp.sendAction(obsoleteAction,to:obsoleteTarget,from:obsoleteDay)
        try require(callbacks.model.authorDate==replacementDate,"A dismantled date coordinator changed the replacement document")
        guard let currentDay=views(callbacks.window?.contentView).compactMap({$0 as? NSDatePicker}).first(where:{$0.datePickerElements == .yearMonthDay}),let currentTarget=currentDay.target,let currentAction=currentDay.action else {throw Failure(description:"Replacement date target absent")}
        callbacks.close()
        identity.isEnabled=true;identity.isEditable=true;identity.stringValue="retired <late@example.invalid>"
        identityCallback.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:identity))
        currentDay.isEnabled=true;currentDay.dateValue=limits.lowerBound;NSApp.sendAction(currentAction,to:currentTarget,from:currentDay)
        try require(callbacks.model.author==acceptedAuthor && callbacks.model.authorDate==replacementDate && !callbacks.model.messageFocusAvailable,"Retired author/date controls changed closed draft")
        try await wait {CommitWindowModel.activeMetadataOperations==0}
        trace("cancelled metadata readers retain actual lifetime")
        let identityRead=CommitWindowModel(repository:repo,access:nil,unversionedDefaults:prefs,dialogDefaults:prefs)
        let dateRead=CommitWindowModel(repository:repo,access:nil,unversionedDefaults:prefs,dialogDefaults:prefs)
        let amendRead=CommitWindowModel(repository:repo,access:nil,unversionedDefaults:prefs,dialogDefaults:prefs)
        for reader in [identityRead,dateRead,amendRead] {
            reader.reload();try await wait {!reader.busy && reader.commitIdentityPrepared}
            try require(reader.error==nil,"Metadata cancellation owner initialization failed")
        }
        var authorReply:CheckedContinuation<String?,Never>?,dateReply:CheckedContinuation<Date?,Never>?,amendReply:CheckedContinuation<String?,Never>?
        var authorToken:OperationCancellation?,dateToken:OperationCancellation?,amendToken:OperationCancellation?
        defer {
            identityRead.invalidateForClose();dateRead.invalidateForClose();amendRead.invalidateForClose()
            authorReply?.resume(returning:nil);dateReply?.resume(returning:nil);amendReply?.resume(returning:nil)
        }
        identityRead.queryCommitAuthor={_,token in authorToken=token;return await withCheckedContinuation{authorReply=$0}}
        dateRead.queryCommitAuthorDate={token in dateToken=token;return await withCheckedContinuation{dateReply=$0}}
        amendRead.queryAmendMessage={token in amendToken=token;return await withCheckedContinuation{amendReply=$0}}
        identityRead.setAuthor=true;identityRead.author="held author";identityRead.authorChanged()
        dateRead.amend=true;dateRead.setAuthorDate=true;dateRead.authorDate=clock;dateRead.dateChanged()
        amendRead.amend=true;amendRead.message="held draft";amendRead.amendChanged()
        try await wait {authorReply != nil && dateReply != nil && amendReply != nil}
        try require(CommitWindowModel.activeMetadataOperations==3,"Author/date/amend workers have no actual shared ownership")
        let metadataQuit=TurtleGitApplicationDelegate()
        try require(metadataQuit.applicationShouldTerminate(NSApp) == .terminateCancel,"Application Quit ignored actual author/date/amend workers")
        identityRead.invalidateForClose();dateRead.invalidateForClose();amendRead.invalidateForClose()
        try require(authorToken?.isCancelled==true && dateToken?.isCancelled==true && amendToken?.isCancelled==true && CommitWindowModel.activeMetadataOperations==3,"Retirement released cancelled metadata workers before their real return")
        authorReply?.resume(returning:"late author");authorReply=nil
        dateReply?.resume(returning:limits.lowerBound);dateReply=nil
        amendReply?.resume(returning:"late amend");amendReply=nil
        try await wait {CommitWindowModel.activeMetadataOperations==0}
        try require(identityRead.author=="held author" && dateRead.authorDate==clock && amendRead.message=="held draft" && [identityRead,dateRead,amendRead].allSatisfy{!$0.messageFocusAvailable && $0.error==nil},"Cancelled metadata published into a retired Commit owner")
        trace("staging and submodule policy")
        // Staging mode keeps source submodule automatic-selection policy editable without Git mutations.
        let revision=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","--add","--cacheinfo","160000,"+revision+",module"])
        let stagedTree=try await repo.run(["write-tree"]).stdout,stagedHead=try await repo.run(["rev-parse","HEAD"]).stdout
        let policyOwner=make();policyOwner.model.reload();try await settled(policyOwner.model)
        try require(policyOwner.model.submodules.contains("module"),"Fixture gitlink absent")
        policyOwner.model.setStagingEnabled(true);try await settled(policyOwner.model)
        let stagedChecks=policyOwner.model.checked,stagedPaths=policyOwner.model.entries.filter{policyOwner.model.isStaged($0)}.map(\.path)
        policyOwner.model.setDoNotAutoselectSubmodules(true)
        try require(policyOwner.model.doNotAutoselectSubmodules && prefs.bool(forKey:"Commit.DoNotAutoselectSubmodules"),"Staging mode rejected submodule policy")
        policyOwner.model.setDoNotAutoselectSubmodules(false)
        try require(!policyOwner.model.doNotAutoselectSubmodules && policyOwner.model.checked==stagedChecks && policyOwner.model.entries.filter{policyOwner.model.isStaged($0)}.map(\.path)==stagedPaths,"Staging policy changed index check state")
        policyOwner.model.setStagingEnabled(false);try await settled(policyOwner.model)
        policyOwner.model.setDoNotAutoselectSubmodules(true);try require(!policyOwner.model.checked.contains("module"),"Classic policy failed to uncheck submodules")
        policyOwner.model.setDoNotAutoselectSubmodules(false);try require(policyOwner.model.checked.contains("module"),"Classic policy failed to reselect submodules")
        let finalTree=try await repo.run(["write-tree"]).stdout,finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalTree==stagedTree && finalHead==stagedHead,"Automatic submodule policy/mode changed Git index/HEAD")
        trace("final owner retirement")
        owners.forEach{$0.close()};try await wait {CommitWindowModel.activeReloads==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeMetadataOperations==0}
        trace("final owned work drained")
        print("PASS: Commit visibility/empty/error/retry/prompt ownership/submodule policy")
    }
}
