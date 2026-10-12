import XCTest
import CoreServices
@testable import TurtleGitCore

final class RepositoryFileEventTests:XCTestCase {
    final class Recorder:@unchecked Sendable {
        let lock=NSLock();var events:[RepositoryFileEvent]=[]
        func append(_ values:[RepositoryFileEvent]) { lock.lock();events += values;lock.unlock() }
        func snapshot() -> [RepositoryFileEvent] { lock.lock();defer { lock.unlock() };return events }
    }
    func testActualFilesystemEventsAndRetiredStream() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEvents-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let recorder=Recorder(),monitor=try RepositoryFileEventMonitor(roots:[root,root],latency:0.05,onEvents:recorder.append)
        defer { monitor.stop() }
        XCTAssertEqual(monitor.roots,[root.standardizedFileURL])
        let file=root.appendingPathComponent("Unicode 雪\nfile")
        try Data("created\n".utf8).write(to:file)
        for _ in 0..<1000 { if recorder.snapshot().contains(where: { URL(fileURLWithPath:$0.path).resolvingSymlinksInPath()==file.resolvingSymlinksInPath() }) { break };try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertTrue(recorder.snapshot().contains { URL(fileURLWithPath:$0.path).resolvingSymlinksInPath()==file.resolvingSymlinksInPath() },"Observed: \(recorder.snapshot().map(\.path))")
        try FileManager.default.moveItem(at:file,to:root.appendingPathComponent("renamed"))
        for _ in 0..<1000 { if recorder.snapshot().contains(where: { URL(fileURLWithPath:$0.path).resolvingSymlinksInPath()==root.appendingPathComponent("renamed").resolvingSymlinksInPath() }) { break };try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertTrue(recorder.snapshot().contains { URL(fileURLWithPath:$0.path).resolvingSymlinksInPath()==root.appendingPathComponent("renamed").resolvingSymlinksInPath() },"Observed: \(recorder.snapshot().map(\.path))")
        monitor.stop();try await Task.sleep(nanoseconds:100_000_000)
        let count=recorder.snapshot().count
        try Data("after retirement\n".utf8).write(to:root.appendingPathComponent("after-stop"));try await Task.sleep(nanoseconds:300_000_000)
        XCTAssertEqual(recorder.snapshot().count,count)
    }
    func testRescanFlagsAndInvalidWatchRoots() throws {
        XCTAssertThrowsError(try RepositoryFileEventMonitor(roots:[],onEvents:{ _ in }))
        XCTAssertThrowsError(try RepositoryFileEventMonitor(roots:[URL(string:"https://example.invalid")!],onEvents:{ _ in }))
        XCTAssertFalse(RepositoryFileEvent(path:"file",flags:UInt32(kFSEventStreamEventFlagItemModified)).requiresFullRescan)
        for flag in [kFSEventStreamEventFlagMustScanSubDirs,kFSEventStreamEventFlagUserDropped,kFSEventStreamEventFlagKernelDropped,kFSEventStreamEventFlagRootChanged,kFSEventStreamEventFlagUnmount] {
            XCTAssertTrue(RepositoryFileEvent(path:"/",flags:UInt32(flag)).requiresFullRescan)
        }
    }
    func testLinkedWorktreeWatchDirectoriesPreserveNewlinesAndCancellation() async throws {
        let (root,repo,_) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let linked=root.appendingPathComponent("linked 雪\nworktree")
        _ = try await repo.run(["worktree","add","--detach",linked.path,"HEAD"])
        let child=GitRepository(root:linked,executable:repo.executable)
        let paths=try await child.finderWatchDirectories()
        XCTAssertEqual(paths.first,linked.standardizedFileURL)
        XCTAssertTrue(paths.contains(root.appendingPathComponent(".git").standardizedFileURL))
        XCTAssertEqual(paths.count,3)
        let before=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let token=OperationCancellation();token.cancel()
        do { _ = try await child.finderWatchDirectories(cancellation:token);XCTFail("Cancelled discovery continued") } catch is OperationCancellationFailure {}
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(before,after);XCTAssertEqual(index,try Data(contentsOf:root.appendingPathComponent(".git/index")))
    }
    @MainActor func testDebouncedBusyRefreshAndRetirement() async throws {
        var available=false,refreshes=0,reply:CheckedContinuation<Void,Never>?
        let scheduler=RepositoryEventRefresh(delay:10_000_000,available:{ available },refresh:{ refreshes += 1;if refreshes==1 { await withCheckedContinuation { reply=$0 } } })
        for _ in 0..<50 { scheduler.invalidate() }
        try await Task.sleep(nanoseconds:40_000_000);XCTAssertEqual(refreshes,0)
        available=true;scheduler.kick()
        for _ in 0..<100 { if reply != nil { break };try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertEqual(refreshes,1)
        for _ in 0..<50 { scheduler.invalidate() }
        let held=reply;reply=nil;held?.resume()
        for _ in 0..<100 { if refreshes==2 { break };try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertEqual(refreshes,2)
        scheduler.invalidate();scheduler.retire();scheduler.kick();scheduler.invalidate()
        try await Task.sleep(nanoseconds:40_000_000);XCTAssertEqual(refreshes,2)
    }
}
