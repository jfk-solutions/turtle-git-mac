import AppKit
import TurtleGitCore

@main struct BisectProgressVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws { for _ in 0..<2000 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) };throw Failure(description:"Bisect progress timeout at line \(line)") }
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Bisect progress failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Bisect QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let file=root.appendingPathComponent("file");var hashes:[String]=[]
        for index in 0..<8 { try Data("\(index)\n".utf8).write(to:file);try await repo.stage(["file"]);_ = try await repo.commit(message:"step \(index)");hashes.append(try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)) }
        _ = try await repo.run(["update-ref","refs/remotes/origin/good",hashes[0]])
        let suite="TurtleGit.BisectProgress."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(16,forKey:"GitOutputLimitinKiB");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        defer { prefs.removePersistentDomain(forName:suite) }
        let store=ActionLogStore(storageURL:root.appendingPathComponent("private-actions.log"));ProgressActionLog.install(store:store,preferences:prefs)
        let helper=root.appendingPathComponent("stream-git"),marker=root.appendingPathComponent("ready"),release=root.appendingPathComponent("release")
        let script = #"""
        #!/bin/sh
        if [ "$4-$5" = "$TG_BISECT_MATCH" ]; then
          printf 'Work: 10%%\rWork: 45%%\r\nUnicode '
          printf '\351\233'; /bin/sleep 0.06; printf '\252\n'
          printf 'warning: private fixture\n' >&2
          if [ "$TG_BISECT_BIG" = 1 ]; then row=0;while [ "$row" -lt 32 ];do printf '%1024s\n' X;row=$((row+1));done;fi
          : > "$3/ready"
          while [ ! -e "$3/release" ]; do /bin/sleep 0.05; done
        fi
        exec "$TG_BISECT_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        setenv("TG_BISECT_GIT",git.path,1);defer { unsetenv("TG_BISECT_GIT");unsetenv("TG_BISECT_MATCH");unsetenv("TG_BISECT_BIG") }
        let wrapped=GitRepository(root:root,executable:helper)
        @MainActor func gate(_ command:String,big:Bool=false) { try? FileManager.default.removeItem(at:marker);try? FileManager.default.removeItem(at:release);setenv("TG_BISECT_MATCH",command,1);setenv("TG_BISECT_BIG",big ? "1":"0",1) }
        @MainActor func live(_ model:BisectWindowModel) throws { try require(model.busy && model.output.contains("Unicode 雪") && model.output.contains("Work: 45%") && !model.output.contains("Work: 10%"),"Live CR/UTF-8 output missing");try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Bisect Quit ownership missing") }
        let controller=BisectWindowController(repository:wrapped,access:nil,good:" remotes/origin/good ",bad:"HEAD",preferences:prefs),model=controller.model
        defer { controller.close() }
        var attemptReceipts:[BisectMutationResult]=[];model.onAttemptCompleted={attemptReceipts.append($0)}
        try await wait { !model.busy };try require(model.canStart && model.choices.contains("remotes/origin/good"),"Start choices/defaults missing")
        // Captured picker fields reject a late changed-target response and a closed parent.
        var choose:((LogEntry?)->Void)?,child:LogWindowController?
        controller.makePicker={ repository,access,revision,preferences,reply in choose=reply;let picker=LogWindowController(repository:repository,access:access,onChoose:reply,labelDefaults:preferences,initialRevision:revision);child=picker;return picker }
        controller.presentPicker={_,_ in true};controller.chooseRevision(good:true)
        try require(model.hasPicker,"Picker ownership missing");model.good="origin/good"
        let entry=try await repo.history().first!;choose?(entry)
        try require(model.good == "origin/good" && model.hasPicker,"Picker published before its actual child retired")
        child?.close();try await wait {!model.hasPicker && !controller.hasPendingWork};child=nil
        try require(model.good == "origin/good","Changed picker target accepted stale result")
        // A fresh accepted result also waits for actual close; Cancel must not
        // replace the captured draft. Both continuations settle exactly once.
        controller.chooseRevision(good:true);try require(model.hasPicker,"Fresh picker was not owned")
        choose?(entry);try require(model.good == "origin/good" && model.hasPicker,"Accepted picker published before child close")
        child?.close();try await wait {!model.hasPicker && !controller.hasPendingWork};child=nil
        try require(model.good == entry.hash,"Accepted current picker lost its revision")
        choose?(nil);try require(model.good == entry.hash,"Duplicate picker callback changed accepted revision")
        controller.chooseRevision(good:true);try require(model.hasPicker,"Cancel picker was not owned")
        choose?(nil);child?.close();try await wait {!model.hasPicker && !controller.hasPendingWork};child=nil
        try require(model.good == entry.hash,"Picker Cancel replaced the captured revision")
        try Data("dirty tracked\n".utf8).write(to:file);model.confirmStash={true};model.good=" remotes/origin/good "
        var raw="";model.onChanged={raw=$0};gate("bisect-good");model.start()
        try await wait { FileManager.default.fileExists(atPath:marker.path) && model.output.contains("Unicode 雪") };try live(model);try require(model.percentage == 45 && model.showingProgress,"Progress layout/percentage missing")
        controller.window?.contentView?.layoutSubtreeIfNeeded();try await wait { descendants(controller.window!.contentView!).contains { $0 is SubmoduleProgressTextView } }
        let text=descendants(controller.window!.contentView!).compactMap {$0 as? SubmoduleProgressTextView}.first!;try await wait { text.string == model.output }
        let clipboard=NSPasteboard.withUniqueName();defer { clipboard.releaseGlobally() };text.clipboard=clipboard;text.copyAllInformation(nil);try require(clipboard.string(forType:.string) == model.output && text.outputMenu().items.last?.image != nil,"Bisect native copy icon menu missing")
        try Data().write(to:release);try await wait { !model.busy }
        try require(model.lastExitCode == 0 && model.state?.active == true && raw.contains("Work: 10%") && !model.output.contains("Work: 10%"),"Original Start result or session lost")
        try require(model.postOperations == BisectOperation.allCases,"Source continuation actions missing")
        let stashes=try await repo.run(["stash","list","--format=%H"]).text.split(separator:"\n");try require(stashes.count == 1,"Explicit stash was lost or reapplied")
        // Cancel a classification; recovery retains the real session and Reset only.
        gate("bisect-good");model.perform(.good);try await wait { FileManager.default.fileExists(atPath:marker.path) && model.output.contains("Unicode 雪") };model.cancel();try await wait { !model.busy }
        try require(model.cancelled && model.state?.active == true && model.postOperations == [.reset],"Cancelled classification lost Reset recovery")
        // Recovery reports cancellation through the real owned SwiftUI alert.
        // Reset is unavailable until its default acknowledgement and native
        // sheet detach; do not bypass that contract by clearing model.error.
        guard let cancelledError=model.error,let parent=controller.window else {throw Failure(description:"Cancellation lost its owned error/result")}
        let cancelledOutput=model.output,cancelledHead=model.state?.head,cancelledExit=model.lastExitCode
        var acknowledgement:NSButton?,errorSheet:NSWindow?
        try await wait {
            parent.contentView?.layoutSubtreeIfNeeded()
            guard let sheet=parent.attachedSheet,sheet.sheetParent===parent,let cell=sheet.defaultButtonCell else {return false}
            sheet.contentView?.layoutSubtreeIfNeeded()
            var seen=Set<ObjectIdentifier>()
            let descendants=sheet.contentView.map {Self.descendants($0).compactMap {$0 as? NSButton}} ?? []
            let candidates=([cell.controlView as? NSButton].compactMap {$0}+descendants).filter {seen.insert(ObjectIdentifier($0)).inserted && $0.cell === cell}
            guard candidates.count==1,let button=candidates.first,button.window===sheet,button.isEnabled,!button.isHiddenOrHasHiddenAncestor,
                  let action=button.action,let target=NSApp.target(forAction:action,to:button.target,from:button) as? NSObject,target.responds(to:action) else {return false}
            errorSheet=sheet;acknowledgement=button;return true
        }
        guard let acknowledgement,let errorSheet else {throw Failure(description:"Owned cancellation default acknowledgement missing")}
        try require(model.error==cancelledError && model.output==cancelledOutput && model.state?.head==cancelledHead && model.lastExitCode==cancelledExit && !model.canPerform(.reset),"Cancellation acknowledgment lost result or allowed Reset under its sheet")
        try require(parent.attachedSheet===errorSheet && errorSheet.sheetParent===parent && acknowledgement.window===errorSheet && acknowledgement.cell===errorSheet.defaultButtonCell,"Cancellation acknowledgement changed native owner/default")
        acknowledgement.performClick(nil)
        try await wait {model.error==nil && parent.attachedSheet==nil && errorSheet.sheetParent==nil}
        try require(model.cancelled && model.state?.active==true && model.state?.head==cancelledHead && model.lastExitCode==cancelledExit && model.output==cancelledOutput,"Acknowledgement changed retained cancellation/session/output")
        gate("disabled")
        try require(model.canPerform(.reset),"Reset after cancellation refused admission: retired=\(model.retired) quit=\(model.confirmingQuit) picker=\(model.hasPicker) busy=\(model.busy) pending=\(model.hasPendingWork) confirming=\(model.confirmingCancellation) presentation=\(model.presentationAvailable())")
        let resetReceiptStart=attemptReceipts.count
        model.perform(.reset);try require(model.busy,"Admitted Reset did not start owned work")
        try await wait { !model.busy }
        // Preserve the original model assertion's exact readiness boundary:
        // independent diagnostic reads below must not provide extra settlement.
        let settledResetState=model.state,settledResetExit=model.lastExitCode,settledResetError=model.error,settledResetOutput=model.output
        let resetReceipts=attemptReceipts.dropFirst(resetReceiptStart).flatMap(\.commands).map {"\($0.arguments) exit=\($0.exitCode) output=\($0.output)"}.joined(separator:"\n")
        let actualResetState=try await repo.bisectState(),actualResetBranch=try await repo.branch()
        let resetDiagnostic="expected=\(hashes.last ?? "nil") actualBranch=\(actualResetBranch) actualHead=\(actualResetState.head) actualActive=\(actualResetState.active) capturedModelHead=\(settledResetState?.head ?? "nil") capturedModelActive=\(String(describing:settledResetState?.active)) capturedExit=\(String(describing:settledResetExit)) capturedError=\(settledResetError ?? "nil") receipts=\(resetReceipts) capturedOutput=\(settledResetOutput)"
        print("BISECT_RESET: "+resetDiagnostic)
        try require(settledResetState?.active == false && settledResetState?.head == hashes.last,"Reset lost original branch: "+resetDiagnostic)
        try require(!actualResetState.active && actualResetState.head==hashes.last && actualResetBranch=="main","Reset repository differs from original branch: "+resetDiagnostic)
        model.saveActionLog();let saved=try store.read();try require(saved.contains("User cancelled") && saved.contains("Unicode 雪"),"Attempt Action log was not preserved")
        // Captured policy, pending question and duplicate late Yes retain natural Reset success.
        prefs.set(true,forKey:"ConfirmKillProcess");prefs.set(2,forKey:"AutoCloseGitProgress")
        _ = try await repo.startBisect(good:hashes[0],bad:"HEAD")
        model.load();try await wait { !model.busy };gate("bisect-reset");var answer:((Bool)->Void)?,closes=0;model.confirmCancellation={answer=$0};model.close={closes += 1};model.perform(.reset)
        try await wait { FileManager.default.fileExists(atPath:marker.path) && model.output.contains("Unicode 雪") };model.cancel();try require(model.confirmingCancellation && answer != nil,"Source kill question missing")
        try Data().write(to:release);try await wait { !model.busy };try require(closes == 0 && model.lastExitCode == 0,"Pending question allowed premature close")
        answer?(false);answer?(true);try require(closes == 1 && !model.cancelled,"Duplicate response changed natural success")
        // Forced retirement freezes bounded display and suppresses callbacks through process settlement.
        prefs.set(false,forKey:"ConfirmKillProcess");let retired=BisectWindowModel(repository:wrapped,access:nil,preferences:prefs)
        retired.load(good:hashes[0],bad:"HEAD");try await wait { !retired.busy };gate("bisect-good",big:true);var callbacks=0;retired.onChanged={_ in callbacks += 1};retired.start();try await wait { FileManager.default.fileExists(atPath:marker.path) && retired.output.contains("Output truncated") }
        try require(retired.output.utf8.count < 17000,"Output cap exceeded");let before=retired.output;retired.retire();try require(BisectWindowModel.activeOperations > 0,"Retirement dropped live operation");try await wait { BisectWindowModel.activeOperations == 0 && LocalGitCommandProgress.activeOperations == 0 }
        try require(retired.output == before && callbacks == 0,"Retired Bisect published late result");_ = try await repo.bisect(.reset)
        controller.close();print("Bisect connected family: source layouts/actions, stale picker guards, remote prefix, explicit retained Stash, live multicommand CR/UTF-8/copy icons, bounded output, interrupted-session Reset, Action log, kill/autoclose settlement and forced retirement/Quit passed. Owned window closed; private fixtures/preferences/clipboard.")
    }
}
