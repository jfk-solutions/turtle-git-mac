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
        try await wait { !model.busy };try require(model.canStart && model.choices.contains("remotes/origin/good"),"Start choices/defaults missing")
        // Captured picker fields reject a late changed-target response and a closed parent.
        var choose:((LogEntry?)->Void)?,child:LogWindowController?
        controller.makePicker={ repository,access,revision,preferences,reply in choose=reply;let picker=LogWindowController(repository:repository,access:access,onChoose:reply,labelDefaults:preferences,initialRevision:revision);child=picker;return picker }
        controller.presentPicker={_,_ in true};controller.chooseRevision(good:true)
        try require(model.hasPicker,"Picker ownership missing");model.good="origin/good"
        let entry=try await repo.history().first!;choose?(entry);try require(model.good == "origin/good" && !model.hasPicker,"Changed picker target accepted stale result");child?.close();child=nil
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
        gate("disabled");model.perform(.reset);try await wait { !model.busy };try require(model.state?.active == false && model.state?.head == hashes.last,"Reset lost original branch")
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
