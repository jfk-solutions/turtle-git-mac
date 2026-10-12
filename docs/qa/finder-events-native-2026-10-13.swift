import AppKit
import TurtleGitCore

@main struct FinderEventVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    final class Snapshots:@unchecked Sendable {
        let lock=NSLock();var values:[FinderSnapshot]=[]
        func write(_ value:FinderSnapshot) throws -> Bool { lock.lock();values.append(value);lock.unlock();return true }
        func snapshot() -> [FinderSnapshot] { lock.lock();defer { lock.unlock() };return values }
    }
    static func require(_ condition:Bool,_ message:String) throws { if !condition { throw Failure(description:message) } }
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2000 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) };throw Failure(description:"Finder event timeout at \(line)")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Finder event failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),engine=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:engine)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Finder Event QA"),("user.email","events@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let file=root.appendingPathComponent("file");try Data("baseline\n".utf8).write(to:file);try await repo.stage(["file"]);_ = try await repo.commit(message:"Event baseline")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let snapshots=Snapshots(),model=RepositoryModel(startMonitoring:true,initializePreferences:false,repositoryFactory:{ GitRepository(root:$0,executable:engine) },snapshotWriter:snapshots.write)
        var notifications=0;model.notifyFinder={ notifications += 1 }
        defer { model.closeRepository() }
        model.open(root);try await wait { !model.busy && model.root?.path==root.path && !snapshots.snapshot().isEmpty }
        try require(model.error==nil,"Initial repository load")
        try Data("externally edited\n".utf8).write(to:file)
        try await wait { !model.busy && model.entries.contains { $0.path=="file" && $0.state == .modified } }
        try require(snapshots.snapshot().last?.states[file.path] == .modified && notifications>1,"Event-driven snapshot/notification")
        let reads=snapshots.snapshot().count
        model.busy=true
        for count in 0..<20 { try Data("queued \(count)\n".utf8).write(to:root.appendingPathComponent("queued")) }
        try await Task.sleep(nanoseconds:600_000_000)
        try require(snapshots.snapshot().count==reads,"Busy refresh ran early")
        model.busy=false
        try await wait { !model.busy && model.entries.contains { $0.path=="queued" } }
        try require(snapshots.snapshot().count<=reads+2,"Event burst did not coalesce")
        // Automatic reads must leave Git's index and HEAD unchanged.
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(head==afterHead && index==afterIndex,"Automatic status reads wrote repository state")
        model.confirmingQuit=true
        try Data("quit deferred\n".utf8).write(to:root.appendingPathComponent("deferred"));try await Task.sleep(nanoseconds:500_000_000)
        try require(!model.entries.contains { $0.path=="deferred" },"Quit confirmation lost refresh gate")
        model.confirmingQuit=false;try await wait { !model.busy && model.entries.contains { $0.path=="deferred" } }
        model.closeRepository();let closedReads=snapshots.snapshot().count
        try Data("closed\n".utf8).write(to:root.appendingPathComponent("closed"));try await Task.sleep(nanoseconds:600_000_000)
        try require(model.root==nil && snapshots.snapshot().count==closedReads,"Retired repository monitor published")
        // Shared Git admin changes outside a linked worktree must refresh it.
        let linked=root.appendingPathComponent("linked"),child=GitRepository(root:linked,executable:engine)
        _ = try await repo.run(["worktree","add","--detach",linked.path,"HEAD"])
        model.open(linked);do { try await wait { !model.busy && model.root?.path==linked.path } } catch { fputs("Linked state: busy=\(model.busy), root=\(String(describing:model.root)), expected=\(linked), error=\(String(describing:model.error)), finder=\(model.finderStatus)\n",stderr);throw error }
        let beforeShared=snapshots.snapshot().count
        _ = try await repo.run(["config","turtlegit.event-test","true"])
        try await wait { !model.busy && snapshots.snapshot().count>beforeShared }
        let linkedHead=try await child.run(["rev-parse","HEAD"]).stdout
        try require(linkedHead==head,"Shared-admin notification moved child HEAD")
        model.closeRepository()
        // Registered child scans must also avoid optional index writes.
        let source=root.appendingPathComponent("child-source"),sourceRepo=GitRepository(root:source,executable:engine)
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        _ = try await sourceRepo.run(["init","-b","main"])
        for (key,value) in [("user.name","Child QA"),("user.email","child@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await sourceRepo.run(["config",key,value]) }
        try Data("child baseline\n".utf8).write(to:source.appendingPathComponent("child-file"));try await sourceRepo.stage(["child-file"]);_ = try await sourceRepo.commit(message:"Child baseline")
        _ = try await repo.run(["-c","protocol.file.allow=always","submodule","add","--",source.path,"module"])
        try await repo.stage([".gitmodules","module"]);_ = try await repo.commit(message:"Register child")
        let checkout=root.appendingPathComponent("module"),moduleRepo=GitRepository(root:checkout,executable:engine)
        var indexPath=try await moduleRepo.run(["rev-parse","--path-format=absolute","--git-path","index"]).stdout
        if indexPath.last==10 { indexPath.removeLast() };let childIndex=URL(fileURLWithPath:String(decoding:indexPath,as:UTF8.self)),rawIndex=try Data(contentsOf:childIndex)
        model.open(root);try await wait { !model.busy && model.root?.path==root.path }
        try Data("child changed\n".utf8).write(to:checkout.appendingPathComponent("child-file"))
        try await wait { !model.busy && snapshots.snapshot().last?.states[checkout.appendingPathComponent("child-file").path] == .modified }
        try require(try Data(contentsOf:childIndex)==rawIndex,"Automatic child scan wrote its index")
        model.closeRepository()
        print("Finder events: actual working-file edits and burst coalescing publish snapshots/notifications, busy and Quit deferral, non-writing status reads, close retirement, linked-worktree shared-admin changes, and registered child edits with exact index-byte preservation passed. Private snapshots only; no Finder activation or user preferences changed.")
    }
}
