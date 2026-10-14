import AppKit
import TurtleGitCore

@main struct ConflictReviewVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Conflict review timeout at line \(line)")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Conflict review failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let fixture=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.ConflictReview."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(16,forKey:"GitOutputLimitinKiB");prefs.set(0,forKey:"AutoCloseGitProgress")
        defer { prefs.removePersistentDomain(forName:suite) }
        ProgressActionLog.install(store:ActionLogStore(storageURL:fixture.appendingPathComponent("private-actions.log")),preferences:prefs)
        func initialize(_ root:URL) async throws -> GitRepository {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let repo=GitRepository(root:root,executable:git);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Conflict QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) };return repo
        }
        let root=fixture.appendingPathComponent("delete"),repo=try await initialize(root),path="-conflict 雪\n[*].txt"
        try Data("base\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"base")
        _ = try await repo.run(["switch","-c","side"]);try Data("theirs\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"theirs")
        _ = try await repo.run(["switch","main"]);_ = try await repo.run(["rm","--",path]);_ = try await repo.commit(message:"deleted mine")
        do { _ = try await repo.run(["merge","--no-edit","side"]);throw Failure(description:"Expected delete/modify conflict") } catch is GitFailure {}
        let originalIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let chooser=DeleteConflictWindowController(repository:repo,access:nil,path:path,preferences:prefs)
        defer { chooser.close() }
        chooser.configureComparison={ $0.openExternalComparison={ _,_,_,_ in false } }
        chooser.model.load()
        do { try await wait { !chooser.model.busy && (chooser.model.details != nil || chooser.model.error != nil) } }
        catch { throw Failure(description:"Initial Delete read did not settle: active \(chooser.model.operation.active), busy \(chooser.model.busy), error \(chooser.model.error ?? "none")") }
        try require(chooser.model.details != nil,"Initial Delete read failed: " + (chooser.model.error ?? "none"))
        try require(chooser.model.operation.canInteract && chooser.model.details!.canCompare,"Compare unavailable: active \(chooser.model.operation.active), busy \(chooser.model.busy), child \(chooser.model.operation.hasChild), question \(chooser.model.operation.hasQuestion), progress \(chooser.model.operation.showingProgress), stages \(chooser.model.details!.entry.stages.map(\.number))")
        let presentComparison=chooser.model.onComparison
        chooser.model.onComparison={ prepared in print("Prepared stage-1 comparison; forwarding native presentation");presentComparison(prepared) }
        chooser.model.compare()
        do { try await wait { chooser.comparison != nil || chooser.model.error != nil } }
        catch { throw Failure(description:"Comparison handoff did not settle: active \(chooser.model.operation.active), busy \(chooser.model.busy), child \(chooser.model.operation.hasChild), counters \(ConflictReviewOperation.activeOperations), error \(chooser.model.error ?? "none")") }
        try require(chooser.comparison != nil,"Comparison preparation failed: " + (chooser.model.error ?? "unknown"))
        let child=chooser.comparison!;child.model.load()
        try await wait { !child.model.busy && !child.model.filtering && (child.model.alignment != nil || child.model.error != nil) }
        try require(child.model.error == nil && child.model.document != nil,"Comparison load failed: " + (child.model.error ?? "missing document"))
        let document=child.model.document!
        try require(document.base.text == "base\n" && document.destination.text == "theirs\n","Native comparison did not read stage 1/current content")
        try require(!child.model.canEdit(base:true) && child.model.canEdit(base:false),"Comparison editing sides incorrect")
        try require(chooser.model.operation.hasChild && !chooser.windowShouldClose(chooser.window!),"Parent closed while viewer active")
        let reviewed=try await repo.saveConflictBaseComparison(chooser.model.details!.entry,document:document,text:"reviewed\n")
        child.model.load();try await wait { !child.model.busy && child.model.document?.destination.text == reviewed.destination.text }
        child.close();try await wait { chooser.comparison == nil && !chooser.model.busy }
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == originalIndex,"Comparison saved into index")
        var logged="";chooser.model.onLog={logged=$0};let revision=chooser.model.details!.second.commit!
        chooser.model.log(revision);try await wait { !chooser.model.busy };try require(logged == revision,"Exact incoming Log handoff missing")
        chooser.close()
        // Real add subprocess streams before mutation, then is cancelled/reaped.
        let helper=root.appendingPathComponent("stream-git"),marker=root.appendingPathComponent("ready")
        let script = #"""
        #!/bin/sh
        if [ "$4" = add ]; then
          printf 'Work: 10%%\rWork: 35%%\r\nUnicode '; printf '\351\233'; /bin/sleep 0.06; printf '\252\n'
          : > "$3/ready"
          while :; do /bin/sleep 0.05; done
        fi
        exec "$TG_CONFLICT_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        setenv("TG_CONFLICT_GIT",git.path,1);defer { unsetenv("TG_CONFLICT_GIT") }
        let slow=DeleteConflictWindowController(repository:GitRepository(root:root,executable:helper),access:nil,path:path,preferences:prefs)
        defer { slow.close() }
        slow.model.load();try await wait { !slow.model.busy && slow.model.details != nil };slow.model.resolve(deleting:false)
        try await wait { FileManager.default.fileExists(atPath:marker.path) && slow.model.operation.output.contains("Unicode 雪") }
        try require(slow.model.operation.output.contains("Work: 35%") && !slow.model.operation.output.contains("Work: 10%"),"Delete progress did not normalize CR output")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit lost conflict mutation")
        slow.model.operation.cancel();try await wait { !slow.model.busy }
        try require(slow.model.operation.cancelled && slow.model.operation.active,"Cancelled review did not retain retry view")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == originalIndex,"Cancelled add changed index")
        slow.model.back();try await wait { !slow.model.busy && slow.model.details != nil };slow.close()
        let keep=DeleteConflictWindowController(repository:repo,access:nil,path:path,preferences:prefs);var changed=""
        keep.model.onChanged={changed=$0};keep.model.load();try await wait { !keep.model.busy && keep.model.details != nil };keep.model.resolve(deleting:false)
        try await wait { !keep.model.operation.active && ConflictReviewOperation.activeOperations == 0 }
        let contents=try await repo.run(["show",":"+path]).text,after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(contents == "reviewed\n" && after == head,"Modified did not stage reviewed content without commit")
        // Initialized submodule with divergent parent gitlinks and actual child HEAD.
        let parentRoot=fixture.appendingPathComponent("submodule"),parent=try await initialize(parentRoot),moduleRoot=parentRoot.appendingPathComponent("module"),module=try await initialize(moduleRoot)
        let file=moduleRoot.appendingPathComponent("file")
        try Data("base\n".utf8).write(to:file);try await module.stage(["file"]);_ = try await module.commit(message:"base")
        let base=try await module.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await module.run(["switch","-c","side"]);try Data("theirs\n".utf8).write(to:file);try await module.stage(["file"]);_ = try await module.commit(message:"theirs")
        let theirs=try await module.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await module.run(["switch","main"]);try Data("mine\n".utf8).write(to:file);try await module.stage(["file"]);_ = try await module.commit(message:"mine")
        let mine=try await module.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await parent.run(["update-index","--add","--cacheinfo","160000,"+base+",module"]);_ = try await parent.commit(message:"base link")
        _ = try await parent.run(["switch","-c","side"]);_ = try await parent.run(["update-index","--cacheinfo","160000,"+theirs+",module"]);_ = try await parent.commit(message:"theirs link")
        _ = try await parent.run(["switch","main"]);_ = try await parent.run(["update-index","--cacheinfo","160000,"+mine+",module"]);_ = try await parent.commit(message:"mine link")
        do { _ = try await parent.run(["merge","--no-edit","side"]);throw Failure(description:"Expected gitlink conflict") } catch is GitFailure {}
        let links=try await parent.run(["ls-files","--stage","-z"]).stdout,parentHead=try await parent.run(["rev-parse","HEAD"]).stdout
        let late=SubmoduleConflictWindowController(repository:parent,access:nil,path:"module",preferences:prefs)
        var answer:((NSApplication.ModalResponse)->Void)?;late.sheets.present={_,_,reply in answer=reply;return true}
        late.model.load();try await wait { !late.model.busy && late.model.details != nil };late.model.choose(late.model.details!.theirs)
        try await wait { answer != nil && late.model.operation.hasQuestion };late.close();answer?(.alertFirstButtonReturn);answer?(.alertFirstButtonReturn)
        try await Task.sleep(nanoseconds:100_000_000)
        let afterLate=try await parent.run(["ls-files","--stage","-z"]).stdout;try require(afterLate == links,"Retired Use this affirmative mutated gitlink")
        let sub=SubmoduleConflictWindowController(repository:parent,access:nil,path:"module",preferences:prefs)
        defer { sub.close() }
        sub.model.confirmChoice={true};sub.model.load();try await wait { !sub.model.busy && sub.model.details != nil }
        var childLog="";sub.model.onLog={ _,revision in childLog=revision };sub.model.log(sub.model.details!.base);try await wait { !sub.model.busy }
        try require(childLog == mine,"Initialized Base child Log did not use checkout HEAD")
        var resetDone:(()->Void)?,resetRevision=""
        sub.model.onReset={ child,revision,done in resetRevision=revision;resetDone=done }
        sub.model.choose(sub.model.details!.theirs);try await wait { !sub.model.busy && sub.model.operation.hasChild }
        try require(resetRevision == theirs,"Reset did not retain selected side")
        sub.model.dismissReset();try await wait { !sub.model.busy && !sub.model.operation.showingProgress };resetDone?()
        try await Task.sleep(nanoseconds:100_000_000)
        let afterDismiss=try await parent.run(["ls-files","--stage","-z"]).stdout;try require(afterDismiss == links,"Dismissed Reset callback resumed old resolution")
        sub.model.choose(sub.model.details!.theirs);try await wait { !sub.model.busy && sub.model.operation.hasChild }
        let childIndex=try Data(contentsOf:moduleRoot.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
        _ = try await module.run(["reset","--soft",theirs]);resetDone?();resetDone?()
        try await wait { !sub.model.operation.active && ConflictReviewOperation.activeOperations == 0 }
        let resolved=try await parent.run(["ls-files","--stage","-z","--","module"]).text,parentAfter=try await parent.run(["rev-parse","HEAD"]).stdout
        try require(resolved == "160000 "+theirs+" 0\tmodule\0" && parentAfter == parentHead,"Reset/retry did not resolve exact gitlink without parent commit")
        try require(try Data(contentsOf:moduleRoot.appendingPathComponent(".git/index")) == childIndex && Data(contentsOf:file) == working,"Resolution changed child index/workfiles after Soft reset")
        print("Delete/Modify native base viewer/editability/reload/exact Log, real streamed cancellation/checked keep and Submodule owned question retirement, checkout-HEAD Log, Reset dismissal/stale retry and actual Soft-reset gitlink resolution passed. All owned windows closed.")
    }
}
