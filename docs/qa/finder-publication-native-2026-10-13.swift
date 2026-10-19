import AppKit
import TurtleGitCore

@main struct FinderPublicationVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ condition:Bool,_ message:String) throws { if !condition { throw Failure(description:message) } }
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2000 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) };throw Failure(description:"Finder publication timeout at \(line)")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Finder publication failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),engine=URL(fileURLWithPath:CommandLine.arguments[2]),store=FinderSnapshotStore(url:folder.appendingPathComponent("cache/status.json"))
        var repos:[GitRepository]=[]
        for name in ["a","b"] {
            let location=folder.appendingPathComponent(name);try FileManager.default.createDirectory(at:location,withIntermediateDirectories:true)
            let repo=GitRepository(root:location,executable:engine);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Publication QA"),("user.email","publish@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            try Data("baseline\n".utf8).write(to:location.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"Publication baseline");repos.append(repo)
        }
        let models=repos.map { _ in RepositoryModel(startMonitoring:true,initializePreferences:false,repositoryFactory:{ GitRepository(root:$0,executable:engine) },snapshotStore:store) }
        defer { models.forEach { $0.closeRepository() } }
        var notifications=0,notificationBeforeWrite=false
        func read() -> FinderSnapshot? { FinderSnapshot.readLive(from:store.url) }
        for (index,model) in models.enumerated() {
            model.notifyFinder={ notifications += 1;if read()?.roots.contains(repos[index].root.path) != true { notificationBeforeWrite=true } }
            model.open(repos[index].root)
        }
        try await wait { models.allSatisfy { !$0.busy && $0.root != nil } && read()?.roots.count==2 }
        try require(models.allSatisfy { $0.error==nil } && notifications>=2 && !notificationBeforeWrite,"Atomic publication/notification order")
        try Data("changed a\n".utf8).write(to:repos[0].root.appendingPathComponent("file"))
        try Data("changed b\n".utf8).write(to:repos[1].root.appendingPathComponent("file"))
        try await wait { repos.allSatisfy { read()?.states[$0.root.appendingPathComponent("file").path] == .modified } }
        // Two separate receiver processes publish concurrently through the shipping store.
        var workers:[Process]=[]
        defer { for worker in workers { if worker.isRunning { worker.terminate() };worker.waitUntilExit() } }
        for index in 0..<2 {
            let directory=folder.appendingPathComponent("worker-\(index)");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let input=["store":store.url.path,"root":directory.appendingPathComponent("repository").path]
            try JSONEncoder().encode(input).write(to:directory.appendingPathComponent("input.json"))
            let worker=Process();worker.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);worker.arguments=[directory.path,engine.path,"finder-publication-worker"]
            try worker.run();workers.append(worker)
        }
        try await wait { (0..<2).allSatisfy { FileManager.default.fileExists(atPath:folder.appendingPathComponent("worker-\($0)/ready").path) } }
        for index in 0..<2 { try Data().write(to:folder.appendingPathComponent("worker-\(index)/go")) }
        try await wait { (0..<2).allSatisfy { FileManager.default.fileExists(atPath:folder.appendingPathComponent("worker-\($0)/published").path) } }
        try require(workers.allSatisfy { $0.isRunning } && read()?.roots.count==4,"Separate live processes lost another root")
        try require(repos.allSatisfy { read()?.states[$0.root.appendingPathComponent("file").path] == .modified },"Workers overwrote app roots")
        for index in 0..<2 { try Data().write(to:folder.appendingPathComponent("worker-\(index)/release")) }
        try await wait { workers.allSatisfy { !$0.isRunning } };for worker in workers { worker.waitUntilExit();try require(worker.terminationStatus==0,"Worker publication failed") }
        try require(read()?.roots.count==2,"Exited workers retained authoritative live roots")
        models[0].stopMonitoringForTermination();await models[0].shutdownFinderPublication()
        let own=try store.begin(root:repos[0].root)
        _ = try store.publish(own,snapshots:[FinderSnapshot(roots:[repos[0].root.path],states:[repos[0].root.appendingPathComponent("file").path:.modified])])
        let pending=try store.begin(root:repos[0].root)
        let removed=try store.remove(root:repos[0].root)
        try require(!removed.roots.contains(repos[0].root.path) && removed.roots.contains(repos[1].root.path),"Removal scope")
        let stale=FinderSnapshot(roots:[repos[0].root.path],states:[repos[0].root.path:.modified])
        try require(try !store.publish(pending,snapshots:[stale]).published,"Removed root revived")
        for model in models {model.closeRepository();model.stopMonitoringForTermination();await model.shutdownFinderPublication()}
        print("Finder publication: two real app models retain independent root changes; notifications follow atomic writes; two separate owned processes merge roots; removal rejects late reads and preserves other roots. Existing snapshot JSON remains readable. Private store only; owned workers reaped.")
    }
}
