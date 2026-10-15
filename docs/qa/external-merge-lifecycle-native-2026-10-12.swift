import AppKit
import TurtleGitCore

@main struct ExternalMergeLifecycleVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws { for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure(description:"Executable tools did not settle at \(line)") }
    @MainActor static func owner()->NSWindow { let w=NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.isReleasedWhenClosed=false;w.orderFront(nil);return w }
    @MainActor static func main() async {do {try await verify()}catch{fputs("FAIL: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:"ExternalMergeNative",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
        func wait(_ ready:()->Bool)async throws{for _ in 0..<1000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:"External merge did not settle",code:1)}
        func owner()->NSWindow{let w=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.isReleasedWhenClosed=false;w.orderFront(nil);return w}
        let synchronous=ExternalMergeSession(owner:nil);var synchronousStops=0
        let done=await synchronous.wait{finish in finish();return{synchronousStops += 1}}
        try require(done && synchronousStops==1,"Synchronous termination leaked observation");synchronous.retire()
        let w=owner(),closed=ExternalMergeSession(owner:w);var finish:(()->Void)?,stops=0
        let waiting=Task{await closed.wait{reply in finish=reply;return{stops += 1}}}
        try await wait{finish != nil};w.close();let accepted=await waiting.value
        try require(!accepted && closed.retired && stops==1,"Caller close left tool wait active")
        finish?();try require(stops==1,"Late termination cleaned twice")
        let cancelled=ExternalMergeSession(owner:nil);var cancelFinish:(()->Void)?,cancelStops=0
        let waitingCancel=Task{await cancelled.wait{reply in cancelFinish=reply;return{cancelStops += 1}}}
        try await wait{cancelFinish != nil};waitingCancel.cancel();let cancellationResult=await waitingCancel.value
        try require(!cancellationResult && cancelled.retired && cancelStops==1,"Cancelled wait remained active");cancelFinish?()
        let promptWindow=owner(),prompt=ExternalMergeSession(owner:promptWindow);var response:((NSApplication.ModalResponse)->Void)?
        prompt.presentConfirmation={_,_,reply in response=reply}
        let question=Task{await prompt.confirmResolution(path:"private.txt")};try await wait{response != nil}
        promptWindow.close();let marked=await question.value;response?(.alertFirstButtonReturn)
        try require(!marked && prompt.retired,"Closed confirmation accepted late Mark Resolved")
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _=try await repo.run(["init","-b","main"]);_=try await repo.run(["config","user.name","Fixture"]);_=try await repo.run(["config","user.email","fixture@example.invalid"])
        let path="conflict 雪.txt",file=root.appendingPathComponent(path)
        try Data("base\n".utf8).write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"base")
        _=try await repo.run(["checkout","-b","side"]);try Data("theirs\n".utf8).write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"theirs")
        _=try await repo.run(["checkout","main"]);try Data("mine\n".utf8).write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"mine")
        _=try await repo.run(["merge","--no-edit","side"],successfulExitCodes:0...1)
        let input=try await repo.externalMergeInputs(path:path),index=root.appendingPathComponent(".git/index"),before=try Data(contentsOf:index)
        let resolutionWindow=owner(),resolution=ExternalMergeSession(owner:resolutionWindow)
        defer{resolution.retire();resolutionWindow.close()}
        resolution.presentConfirmation={_,alert,reply in
            precondition(alert.buttons[1].keyEquivalent=="\r" && alert.buttons[0].keyEquivalent.isEmpty)
            reply(.alertSecondButtonReturn)
        }
        try await resolution.resolveIfConfirmed(repository:repo,entry:input.entry,path:path)
        try require(try Data(contentsOf:index)==before,"No response changed conflict index")
        try Data("resolved exactly\n".utf8).write(to:file)
        resolution.presentConfirmation={_,_,reply in reply(.alertFirstButtonReturn)}
        try await resolution.resolveIfConfirmed(repository:repo,entry:input.entry,path:path)
        let remaining=try await repo.conflicts(),staged=try await repo.run(["show",":"+path]).stdout
        try require(remaining.isEmpty && staged==Data("resolved exactly\n".utf8),"Accepted resolution did not stage exact working bytes")
        let stable=try Data(contentsOf:index);var staleRejected=false
        do{try await resolution.resolveIfConfirmed(repository:repo,entry:input.entry,path:path)}catch{staleRejected=true}
        try require(staleRejected && (try Data(contentsOf:index))==stable,"Stale captured stages accepted")
        try await executableTools(repo:repo,root:root,path:path)
        print("External merge: synchronous/asynchronous wait cleanup, caller-close and task cancellation, late termination and confirmation fencing, No default/no index change, exact working-byte Mark Resolved and stale-stage refusal passed. Original observation checks use mock completion; the added executable family launches owned private CLI helpers. Owned windows closed.")
    }
    @MainActor static func executableTools(repo:GitRepository,root:URL,path:String) async throws {
        let script=root.appendingPathComponent(".git/qa-merge-tool"),marker=root.appendingPathComponent(".git/qa-tool-started"),release=root.appendingPathComponent(".git/qa-tool-release")
        let suite="TurtleGit.CLITools.Native."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        var windows:[NSWindow]=[], reapedPIDs:[Int32]=[]
        defer { if ExternalToolProcesses.activeRequests == 0 { DiffToolApplication.discardAll(); MergeToolApplication.discardAll() } }
        defer { windows.forEach{$0.close()};try? FileManager.default.removeItem(at:script);try? FileManager.default.removeItem(at:marker);try? FileManager.default.removeItem(at:release) }
        func program(_ body:String) throws {
            try Data(("#!/bin/sh\n"+body+"\n").utf8).write(to:script)
            try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:script.path)
        }
        func conflict() async throws -> ExternalMergeInputs {
            _=try await repo.run(["reset","--hard","HEAD"])
            _=try await repo.run(["merge","--no-edit","side"],successfulExitCodes:0...1)
            return try await repo.externalMergeInputs(path:path)
        }
        func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
        var settings=MergeToolPreferences();settings.program.enabled=true;settings.program.applicationPath=script.path;settings.blockWhileMerging=true;settings.trustExitCode=true
        let w=owner();windows.append(w)
        do {
            let first=try await conflict()
            try program(#"/bin/cat "$2" > "$4"; exit 0"#)
            let launched=try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:w,preferences:settings,expectedEntry:first.entry)
            let remaining=try await repo.conflicts(),staged=try await repo.run(["show",":"+path]).stdout
            try require(launched && remaining.isEmpty && staged==first.theirs,"Trusted zero CLI did not resolve exact result")
            let second=try await conflict(),unmerged=try await repo.run(["ls-files","--unmerged","-z"]).stdout
            try program(#"/bin/cat "$2" > "$4"; exit 7"#)
            _=try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:w,preferences:settings,expectedEntry:second.entry)
            let failedStages=try await repo.run(["ls-files","--unmerged","-z"]).stdout
            try require(failedStages==unmerged && !failedStages.isEmpty,"Nonzero CLI resolved conflicts")
            settings.trustExitCode=false
            try program(#"/bin/cat "$2" > "$4"; exit 0"#)
            let question=Task { try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:w,preferences:settings) }
            try await wait { w.attachedSheet != nil }
            try await wait { w.attachedSheet?.contentView.map { descendants($0).compactMap{$0 as? NSButton}.contains{$0.title=="No"} } == true }
            let buttons=descendants(w.attachedSheet!.contentView!).compactMap{$0 as? NSButton}
            let defaultCell=w.attachedSheet?.defaultButtonCell
            try require(defaultCell === buttons.first{$0.title=="No"}?.cell,"Untrusted CLI default cell is \(defaultCell?.title ?? "missing")")
            // AppKit clears displayed keyEquivalent strings; invoke the actual
            // default control, then verify No leaves all conflict stages intact.
            (defaultCell?.controlView as? NSButton)?.performClick(nil)
            _=try await question.value
            let noStages=try await repo.run(["ls-files","--unmerged","-z"]).stdout
            try require(noStages==unmerged,"Default No resolved CLI conflict")
            let accepted=Task { try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:w,preferences:settings) }
            try await wait { w.attachedSheet?.contentView.map { descendants($0).compactMap{$0 as? NSButton}.contains{$0.title=="Mark Resolved"} } == true }
            descendants(w.attachedSheet!.contentView!).compactMap{$0 as? NSButton}.first{$0.title=="Mark Resolved"}!.performClick(nil)
            _=try await accepted.value
            let marked=try await repo.conflicts();try require(marked.isEmpty,"Untrusted CLI confirmation failed")
            // Diff uses the same shell-free executable route and can edit live working bytes.
            let snapshot=try await repo.revisionFileComparison(from:.revision("HEAD"),to:.workingTree,paths:[path])
            let document=try await repo.comparisonFile(snapshot,path:path),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            try program(#"printf 'edited by CLI\n' > "$2"; exit 0"#)
            var diff=DiffToolPreferences();diff.program=settings.program;diff.program.arguments="%base %mine";try diff.save(to:prefs)
            let diffLaunched=try await DiffToolApplication.open(document,root:root,permissions:[],alternate:false,preferences:prefs)
            try await wait { ExternalToolProcesses.activeRequests==0 }
            try require(diffLaunched && (try Data(contentsOf:root.appendingPathComponent(path)))==Data("edited by CLI\n".utf8) && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"CLI Diff did not edit original working file safely")
            // A nonblocking tool outlives its caller; grants and quit lifetime stay owned.
            _=try await conflict();settings.blockWhileMerging=false
            try program(#"printf '%s' "$$" > "$5.tmp"; /bin/mv "$5.tmp" "$5"; while [ ! -f "$6" ]; do /bin/sleep 0.05; done; exit 0"#)
            settings.program.arguments="%base %theirs %mine %merged \"%wtroot/.git/qa-tool-started\" \"%wtroot/.git/qa-tool-release\""
            let nonblocking=owner();windows.append(nonblocking)
            _=try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:nonblocking,preferences:settings)
            try await wait { FileManager.default.fileExists(atPath:marker.path) }
            let runningPID=Int32(try String(contentsOf:marker))!
            nonblocking.close()
            try require(ExternalToolProcesses.activeRequests>0 && kill(runningPID,0)==0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Nonblocking CLI lifetime lost after caller close")
            try Data().write(to:release);try await wait { ExternalToolProcesses.activeRequests==0 }
            try require(kill(runningPID,0) != 0,"Nonblocking CLI was not reaped");reapedPIDs.append(runningPID)
            try FileManager.default.removeItem(at:marker);try FileManager.default.removeItem(at:release)
            // Blocking cancellation owns only this tool's process group.
            settings.blockWhileMerging=true
            try program(#"/bin/sleep 30 & child=$!; trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT; printf '%s %s' "$$" "$child" > "$5.tmp"; /bin/mv "$5.tmp" "$5"; wait "$child""#)
            let closing=owner();windows.append(closing)
            let waiting=Task { try await MergeToolApplication.open(repository:repo,access:nil,path:path,alternate:false,owner:closing,preferences:settings) }
            try await wait { FileManager.default.fileExists(atPath:marker.path) }
            let pids=try String(contentsOf:marker).split(separator:" ").compactMap{Int32($0)}
            closing.close()
            do { _=try await waiting.value;throw Failure(description:"Closed blocking CLI was accepted") } catch is OperationCancellationFailure {}
            try await wait { ExternalToolProcesses.activeRequests==0 }
            try require(pids.count==2 && pids.allSatisfy{kill($0,0) != 0},"Blocking CLI group survived cancellation");reapedPIDs += pids
        } catch {
            windows.forEach{$0.close()};ExternalToolProcesses.cancelAll();try? await wait { ExternalToolProcesses.activeRequests==0 };throw error
        }
        print("Owned executable tool PIDs absent: \(reapedPIDs)")
        print("Executable tools: trusted zero/nonzero resolution, actual No-default confirmation, editable working Diff, nonblocking caller/quit/grant lifetime, blocking close cancellation and owned process reaping passed.")
    }

}
