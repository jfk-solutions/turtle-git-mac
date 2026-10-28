// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Compile with GitSVNFixture.swift. This receiver creates no windows, and uses
/// only owned repositories, a private pasteboard, preferences and Action log.
@main struct SVNActionLogVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static var owners:[SVNWindowModel]=[]
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(_ condition:()->Bool)async throws {
        for _ in 0..<2000 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Owned SVN action-log operation did not drain")
    }
    @MainActor static func main()async {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        setenv("TURTLEGIT_SVN_TEST_GIT",CommandLine.arguments[2],1)
        do {
            try await verify(container:URL(fileURLWithPath:CommandLine.arguments[1]))
            owners.forEach {$0.retire()};try await wait {SVNWindowModel.activeOperations==0};owners=[]
            print("PASS: SVN distinct stage Action logs, preflight exclusion, retry/auto-close/handoff, bounded UTF-8 and retired-worker drain")
        } catch {
            owners.forEach {$0.retire()}
            for _ in 0..<2000 {if SVNWindowModel.activeOperations==0 {break};try? await Task.sleep(nanoseconds:10_000_000)}
            fputs("SVN Action log failure: \(error)\n",stderr);exit(1)
        }
    }
    @MainActor static func verify(container:URL)async throws {
        let suite="TurtleGit.SVN.ActionLog."+UUID().uuidString,preferences=UserDefaults(suiteName:suite)!
        let clipboard=NSPasteboard(name:.init(suite))
        defer {preferences.removePersistentDomain(forName:suite);clipboard.clearContents()}
        preferences.set(0,forKey:"AutoCloseGitProgress");preferences.set(false,forKey:"ShowGitexeTimings")
        let store=ActionLogStore(storageURL:container.appendingPathComponent(suite+"/logfile.txt"))
        defer {try? FileManager.default.removeItem(at:store.storageURL.deletingLastPathComponent())}
        ProgressActionLog.install(store:store,preferences:preferences)
        func text()throws->String {store.exists ? try store.read():""}
        func occurrences(_ needle:String,_ haystack:String)->Int {haystack.components(separatedBy:needle).count-1}
        func model(_ repository:GitRepository,_ operation:GitSVNOperation)->SVNWindowModel {
            let value=SVNWindowModel(repository:repository,access:nil,operation:operation,preferences:preferences,clipboard:clipboard)
            owners.append(value);value.close={ [weak value] in value?.retire()};return value
        }
        let (root,repo,old,next)=try await GitSVNFixture.create()
        defer {try? FileManager.default.removeItem(at:root)}
        let fetch=model(repo,.fetch);fetch.load();try await wait {!fetch.busy}
        try require(fetch.success && !store.exists,"Retained Fetch result logged before dismissal")
        var comparisons=0;fetch.onCompare={_,_ in comparisons+=1}
        guard let fetched=fetch.fetched else {throw Failure(description:"Fetch result missing")}
        fetch.compare(fetched,context:fetch.formContext)
        let fetchedLog=try text();try require(comparisons==1 && fetchedLog.contains("git svn fetch") && fetchedLog.contains("Fetched r2"),"Fetch post-action did not persist its command output")
        fetch.retire();fetch.saveActionLog();try require(try text()==fetchedLog,"Repeated Fetch close duplicated log")
        try store.clear()

        let dcommit=model(repo,.dcommit);dcommit.load();try await wait {!dcommit.busy}
        try require(dcommit.phase == .options && !store.exists,"DCommit options-only page created progress log")
        dcommit.removeEmptyDirectories=true;dcommit.start();try await wait {!dcommit.busy}
        try require(dcommit.success && !store.exists,"DCommit retained result logged prematurely")
        dcommit.retire();try require(try text().contains("git svn dcommit --rmdir"),"DCommit command identity lost")
        try store.clear()

        _=try await repo.run(["config","svn-test.fail","true"])
        let ignore=model(repo,.ignore);ignore.load();try await wait {!ignore.busy};ignore.start();try await wait {!ignore.busy}
        try require(ignore.error != nil && !store.exists,"Failed Ignore result was not retained")
        _=try await repo.run(["config","svn-test.fail","false"])
        ignore.retry();let failureLog=try text()
        try require(failureLog.contains("private failure") && occurrences("git svn show-ignore >",failureLog)==1,"Retry failed to preserve exactly one prior attempt")
        try await wait {!ignore.busy};try require(ignore.success,"Ignore retry did not succeed")
        ignore.retire();let retryLog=try text()
        try require(occurrences("git svn show-ignore >",retryLog)==2,"Retry close conflated or duplicated attempt identity")
        try store.clear()

        _=try await repo.run(["update-ref","refs/remotes/git-svn",old]);_=try await repo.run(["reset","--hard",old])
        let rebase=model(repo,.rebase);rebase.load();try await wait {!rebase.busy}
        let stages=try text()
        try require(rebase.success && stages.contains("git svn fetch") && stages.contains("git reset --hard "+next),"Rebase Fetch and reset did not persist separate intermediate dialogs")
        try require(occurrences(" - "+root.path,stages)==2,"Rebase stages shared a progress-log owner")
        rebase.retire();try require(try text()==stages,"Rebase final close duplicated intermediate records")
        try store.clear()

        // A closed UI must not save an incomplete producer snapshot. The real
        // private Git wrapper stays owned until cancellation drains its pipes.
        let wrapper=repo.executable,original=try String(contentsOf:wrapper)
        let waiting=original.replacingOccurrences(of:"print('Fetched r2');sys.exit(0)",with:"print('retired-prefix',flush=True);(root/'entered-retired').touch();__import__('time').sleep(20);print('retired-tail',flush=True);sys.exit(0)")
        try waiting.write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let retired=model(repo,.fetch);retired.load();try await wait {FileManager.default.fileExists(atPath:root.appendingPathComponent("entered-retired").path)}
        retired.retire();try require(!store.exists && retired.busy,"Forced closure recorded before actual worker drain")
        try await wait {!retired.busy && SVNWindowModel.activeOperations==0}
        let drained=try text();try require(drained.contains("retired-prefix") && drained.contains("User cancelled"),"Retired command lost final output or cancellation")
        retired.saveActionLog();try require(try text()==drained,"Retired drain recorded more than once")
        try original.write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        try store.clear()

        // Parser-owned bytes survive a record request before completion, stay
        // bounded on a UTF-8 boundary and keep only one cancellation suffix.
        preferences.set(16,forKey:"GitOutputLimitinKiB")
        let record=SVNProgressActionRecord(repository:root,preferences:preferences)
        record.parser.appendChunk(Data(String(repeating:"雪🙂\n",count:10_000).utf8));record.record()
        try require(!store.exists,"Unfinished stage wrote an incomplete log")
        record.finish(error:nil,cancelled:true);let bounded=try text()
        try require(record.output.utf8.count<=GitCommandPresentation(defaults:preferences).outputLimit && !record.output.contains("�"),"Stage log exceeded display budget or split UTF-8")
        let expected=ActionLogStore.lines(record.output)+["User cancelled"]
        try require(Array(ActionLogStore.lines(bounded).suffix(expected.count))==expected && occurrences(" - "+root.path,bounded)==1,"Stage log did not preserve exact command output followed by one cancellation suffix")
        record.record();try require(try text()==bounded,"Second completion request duplicated the same stage entry")
    }
}
