import AppKit
import Darwin
import TurtleGitCore

@main struct CloneCompletionVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool)async throws {for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Clone completion wait at \(line)")}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else {return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func main()async {do {try await verify()}catch {fputs("Clone completion failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),source=root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let repo=GitRepository(root:source,executable:git);_ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Clone Completion"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:source.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:source.appendingPathComponent(".git/index"))
        let suite="TurtleGit.CloneCompletion."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,lease=RepositoryAccessLease(url:root)
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(["ssh://host/A","ssh://host/a","ssh://host/é","ssh://host/e\u{301}"]+(0..<30).map {"ssh://host/\($0)"},forKey:"Clone.URLHistory")
        prefs.set(["/tmp/one","/tmp/two"],forKey:"Clone.KeyHistory")
        let history=CloneWindowController(directory:root,access:lease,preferences:prefs,executable:git);defer {history.close()}
        history.window!.alphaValue=0;history.window!.orderFront(nil)
        history.model.makeSSHCoordinator={SSHTransportCoordinator(repository:$0)};history.model.source="ssh://host/repo";history.model.sourceChanged()
        try await wait {views(history.window?.contentView).compactMap {$0 as? EditableHistoryCombo}.count==2}
        let combos=views(history.window?.contentView).compactMap {$0 as? EditableHistoryCombo},url=combos.first {$0.accessibilityLabel()=="Repository URL"}!,key=combos.first {$0.accessibilityLabel()=="OpenSSH private key"}!
        try require(history.model.urls.count==25 && history.model.urls.prefix(4).count==4 && history.model.urls[2].utf16.elementsEqual("ssh://host/é".utf16) && history.model.urls[3].utf16.elementsEqual("ssh://host/e\u{301}".utf16),"History load lost bounds or byte-distinct names")
        url.selectItem(at:1);url.historyPopupOpen=true
        let deletion=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:history.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:51)!
        try require(url.handleHistoryKey(deletion) && !history.model.urls.contains("ssh://host/a") && history.model.urls.contains("ssh://host/A"),"Native URL history deletion lost exact identity")
        try await wait {key.isEnabled};key.selectItem(at:0);key.historyPopupOpen=true
        try require(key.handleHistoryKey(deletion) && history.model.keys==["/tmp/two"] && history.model.key=="/tmp/two","Native key-history deletion failed")
        let late=url.deleteHistory!,saved=prefs.stringArray(forKey:"Clone.URLHistory");history.close();late(0)
        try require(prefs.stringArray(forKey:"Clone.URLHistory")==saved,"Retired combo changed history")
        // Accepted failed attempts save captured histories; invalid submissions do not.
        let occupied=root.appendingPathComponent("occupied");try FileManager.default.createDirectory(at:occupied,withIntermediateDirectories:true);try Data("keep".utf8).write(to:occupied.appendingPathComponent("keep"))
        let draft=CloneWindowModel(directory:root,access:lease,preferences:prefs,executable:git);defer {draft.invalidate()}
        draft.source=source.path;draft.directory=occupied.path;draft.key="/tmp/remember-even-disabled";draft.useKey=false
        var result:CloneProgressWindowModel?;draft.onProgress={result=$0};draft.clone();try await wait {result?.busy==false}
        try require(result?.postActions==[.retry] && prefs.stringArray(forKey:"Clone.URLHistory")?.first==source.path && prefs.stringArray(forKey:"Clone.KeyHistory")?.first=="/tmp/remember-even-disabled","Failed accepted Clone lost source-style history")
        result!.close();let beforeInvalid=prefs.stringArray(forKey:"Clone.URLHistory")
        let invalid=CloneWindowModel(directory:root,access:lease,preferences:prefs,executable:git);defer {invalid.invalidate()};invalid.source="https://invalid.example/never";invalid.directory=root.appendingPathComponent("invalid").path;invalid.useBranch=true;invalid.branch="bad..branch";invalid.clone()
        try await wait {!invalid.activeOperation};try require(invalid.error != nil && prefs.stringArray(forKey:"Clone.URLHistory")==beforeInvalid && !FileManager.default.fileExists(atPath:invalid.directory),"Invalid preflight saved history or created a destination")
        // Real clone runs once; a failed metadata read is retried independently.
        let wrapper=root.appendingPathComponent("counting-git"),calls=root.appendingPathComponent("clone-count")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        try ("#!/bin/sh\nfor argument in \"$@\"; do if [ \"$argument\" = clone ]; then printf 'clone\\n' >> "+quote(calls.path)+"; break; fi; done\nexec "+quote(git.path)+" \"$@\"\n").write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        var options=CloneOptions();options.source=source.path
        let destination=root.appendingPathComponent("retry-opening"),opening=CloneProgressWindowModel(options:options,destination:destination,executable:wrapper,destinationAccess:lease,sourceAccess:lease,keyAccess:nil,preferences:prefs)
        defer {opening.invalidate()};var reads=0,adoptions=0
        opening.inspectRepository={candidate,_,token in reads += 1;if reads==1 {throw Failure(description:"Injected opening failure")};return candidate}
        opening.onCloned={_,_ in adoptions += 1};await opening.run()
        try require(opening.commandCompleted && !opening.success && opening.postActions==[.inspect,.explore] && adoptions==0,"Completed Clone exposed transport Retry or adopted before inspection")
        opening.perform(.retry);try require(!opening.busy,"Stale transport Retry ran after successful Clone")
        opening.perform(.inspect);try require(CloneProgressWindowModel.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Opening retry lost immediate Quit guard")
        try await wait {!opening.busy};try require(opening.success && adoptions==1 && reads==2 && opening.postActions==[.log,.explore] && String(contentsOf:calls)=="clone\n","Opening retry recloned or duplicated adoption")
        // A legacy SVN adapter invokes a real local Git clone and rejects only
        // the post-clone key config. This is not live git-svn/SSH acceptance.
        let warningGit=root.appendingPathComponent("warning-git")
        let script="""
        #!/bin/sh
        task_clone_root="$3"; shift 3
        if [ "$1" = svn ] && [ "$2" = --version ]; then printf 'fixture svn adapter\\n'; exit 0; fi
        if [ "$1" = svn ] && [ "$2" = clone ]; then shift 2; exec \(quote(git.path)) -C "$task_clone_root" clone "$@"; fi
        for argument in "$@"; do case "$argument" in core.sshCommand) printf 'fixture denied key config\\n' >&2; exit 67;; esac; done
        exec \(quote(git.path)) -C "$task_clone_root" "$@"
        """
        try script.write(to:warningGit,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:warningGit.path)
        options.svn=true;options.sshKey=root.appendingPathComponent("unused-key")
        prefs.set(2,forKey:"AutoCloseGitProgress")
        let warning=CloneProgressWindowModel(options:options,destination:root.appendingPathComponent("with-warning"),executable:warningGit,destinationAccess:lease,sourceAccess:lease,keyAccess:nil,preferences:prefs);defer {warning.invalidate()}
        var closes=0,warningAdoptions=0;warning.close={closes += 1};warning.onCloned={_,output in if output.contains("fixture denied key config") {warningAdoptions += 1}}
        await warning.run();try require(warning.success && warning.commandCompleted && warning.warnings.count==1 && warning.postActions==[.log,.explore] && closes==0 && warningAdoptions==1,"SSH configuration warning hid successful clone/actions or auto-closed")
        // A retired inspection reader cannot publish a late adoption.
        options.svn=false;options.sshKey=nil
        let retiring=CloneProgressWindowModel(options:options,destination:root.appendingPathComponent("retiring"),executable:git,destinationAccess:lease,sourceAccess:lease,keyAccess:nil,preferences:prefs);defer {retiring.invalidate()}
        var reply:CheckedContinuation<GitRepository,Never>?,captured:GitRepository?,token:OperationCancellation?
        retiring.inspectRepository={candidate,_,request in captured=candidate;token=request;return await withCheckedContinuation {reply=$0}}
        var lateAdoptions=0;retiring.onCloned={_,_ in lateAdoptions += 1};retiring.start();try await wait {reply != nil};retiring.invalidate()
        try require(token?.isCancelled==true && CloneProgressWindowModel.activeOperations>0,"Forced retirement released reader/token early")
        reply?.resume(returning:captured!);reply=nil;try await wait {CloneProgressWindowModel.activeOperations==0}
        try require(lateAdoptions==0 && !retiring.success,"Retired opening read adopted late")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;try require(after==head && Data(contentsOf:source.appendingPathComponent(".git/index"))==index && Data(contentsOf:occupied.appendingPathComponent("keep"))==Data("keep".utf8),"Completion/history changed source or occupied destination")
        print("PASS Clone completion: exact native history deletion, accepted-failure/invalid history timing, one-clone opening retry and Quit guard, successful SSH-warning actions/manual review, retired reader cancellation, unchanged source/occupied bytes and owned cleanup")
    }
}
