import AppKit
import TurtleGitCore

@main struct FinderServiceGrantVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Service grant failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),engine=URL(fileURLWithPath:CommandLine.arguments[2]),root=folder.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:engine);_ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Grant QA"),("user.email","grant@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("private transfer bytes\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"Grant baseline")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        var lease:RepositoryAccessLease?=RepositoryAccessLease(url:root)
        let request=try FinderServiceAuthorization.capture([(UUID(),root,lease!)])
        try JSONEncoder().encode(request).write(to:folder.appendingPathComponent("transfer.json"),options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:folder.appendingPathComponent("transfer.json").path)
        lease=nil
        let worker=Process();worker.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);worker.arguments=[folder.path,engine.path,"finder-service-grant-worker"]
        try worker.run();defer { if worker.isRunning { worker.terminate() };worker.waitUntilExit() }
        for _ in 0..<2000 { if !worker.isRunning { break };try await Task.sleep(nanoseconds:10_000_000) }
        try require(!worker.isRunning,"Owned transfer receiver timeout");worker.waitUntilExit();try require(worker.terminationStatus==0,"Owned transfer receiver failed")
        let result=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:folder.appendingPathComponent("result.json")))
        try require(result["root"]==root.path && result["bytes"]=="private transfer bytes\n","Receiver grant/root read")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(head==afterHead && index==afterIndex,"Transfer changed repository state")
        print("Private service grants: actual Foundation bookmark encoding/receiver resolution in a separate owned process after sender lease release, exact repository bytes and HEAD/index preservation passed. Unsigned private destinations; security scope requirement explicitly disabled for this fixture, not signed permission proof.")
    }
}
