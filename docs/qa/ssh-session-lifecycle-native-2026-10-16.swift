import AppKit
import Darwin
import TurtleGitCore

struct SSHSessionLifecycleVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    final class Bookmarks:RepositoryBookmarkProvider {
        var starts=0,stops=0
        func create(for url:URL)throws->Data {Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool {starts += 1;return true}
        func stopAccessing(_ url:URL) {stops += 1}
    }
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let repo=GitRepository(root:root,executable:git);_=try await repo.run(["init","-b","main"])
        let app=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app")
        let tools=try SSHAgentRuntime.resolve(bundle:Bundle(url:app)!,appStore:true)
        let key=root.appendingPathComponent("key ' ; literal"),generator=tools.agent.deletingLastPathComponent().appendingPathComponent("ssh-keygen")
        let create=Process();create.executableURL=generator;create.arguments=["-q","-t","ed25519","-N","","-C","lifecycle-fixture","-f",key.path];create.standardInput=FileHandle.nullDevice;create.standardOutput=FileHandle.nullDevice;create.standardError=FileHandle.nullDevice
        try create.run();create.waitUntilExit();try require(create.terminationStatus==0,"Bundled key generation failed")
        let wrapper=root.appendingPathComponent("agent"),pidFile=URL(fileURLWithPath:wrapper.path+".pid")
        let quoted="'"+tools.agent.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        try Data(("#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$0.pid.pending\"\n/bin/mv \"$0.pid.pending\" \"$0.pid\"\nexec "+quoted+" \"$@\"\n").utf8).write(to:wrapper)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let provider=Bookmarks(),store=SSHIdentityAccessStore(storageURL:root.appendingPathComponent("permissions/grants.json"),provider:provider)
        try store.remember(key)
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("tg-sl-"+String(UUID().uuidString.prefix(6)))
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:temporary)}
        let coordinator=SSHTransportCoordinator(repository:repo,identities:store,temporaryRoot:temporary,runtime:{.init(agent:wrapper,add:tools.add,askpass:tools.askpass)})
        defer{coordinator.close()}
        let inheritedSocket=ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],inheritedPID=ProcessInfo.processInfo.environment["SSH_AGENT_PID"]
        let first=try await coordinator.prepareKey(path:key.path,cancellation:.init()),firstPID=try Int32(String(contentsOf:pidFile).trimmingCharacters(in:.whitespacesAndNewlines))!
        try require(first.isRunning && first.publicIdentities().contains("lifecycle-fixture"),"First private identity not loaded")
        let cached=try await coordinator.prepareKey(path:key.path,cancellation:.init());try require(first === cached,"Live private session not reused")
        first.close();try require(!first.isRunning && kill(firstPID,0) != 0,"Closed agent remained live")
        let second=try await coordinator.prepareKey(path:key.path,cancellation:.init()),secondPID=try Int32(String(contentsOf:pidFile).trimmingCharacters(in:.whitespacesAndNewlines))!
        try require(second !== first && second.isRunning && second.publicIdentities().contains("lifecycle-fixture"),"Closed session cache was reused instead of reloading identity")
        // This PID belongs to this fixture's foreground agent, recorded before exec.
        try require(kill(secondPID,SIGTERM)==0,"Could not stop owned fixture agent")
        for _ in 0..<1000 {if !second.isRunning {break};try await Task.sleep(nanoseconds:10_000_000)}
        try require(!second.isRunning,"Exited agent worker did not publish terminal state")
        let unkeyed=try await coordinator.prepare([],cancellation:.init())
        try require(unkeyed == nil && !FileManager.default.fileExists(atPath:second.directory.path),"Unkeyed preparation retained an exited agent socket")
        let third=try await coordinator.prepareKey(path:key.path,cancellation:.init()),thirdPID=try Int32(String(contentsOf:pidFile).trimmingCharacters(in:.whitespacesAndNewlines))!
        try require(third !== second && third.isRunning && third.publicIdentities().contains("lifecycle-fixture") && !FileManager.default.fileExists(atPath:second.directory.path),"Exited agent did not restart/reload/clean its directory")
        let cancelled=OperationCancellation();cancelled.cancel()
        do {_=try await coordinator.prepareKey(path:key.path,cancellation:cancelled);throw Failure(description:"Cancelled preparation succeeded")} catch OperationCancellationFailure.cancelled {}
        try require(third.isRunning && provider.starts==provider.stops && SSHTransportCoordinator.activeOperations==0,"Cancellation dropped the live session or leaked identity access")
        coordinator.close()
        try require(!third.isRunning && [firstPID,secondPID,thirdPID].allSatisfy{kill($0,0) != 0} && FileManager.default.contentsOfDirectory(atPath:temporary.path).isEmpty,"Owned agents/directories were not reaped")
        try require(ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]==inheritedSocket && ProcessInfo.processInfo.environment["SSH_AGENT_PID"]==inheritedPID,"Login agent environment changed")
        print("PASS: actual bundled SSH agent/key loading, live reuse, closed/exited agent cache invalidation and identity reload, private directory/process cleanup, balanced mock grants, pre-cancelled preparation and unchanged login-agent environment; no server or user keys")
    }
}
