import AppKit
import TurtleGitCore

@main struct ExternalMergeLifecycleVerification {
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
        print("External merge: synchronous/asynchronous wait cleanup, caller-close and task cancellation, late termination and confirmation fencing, No default/no index change, exact working-byte Mark Resolved and stale-stage refusal passed. Mock tool completion; no external app killed or launched. Owned windows closed.")
    }
}
