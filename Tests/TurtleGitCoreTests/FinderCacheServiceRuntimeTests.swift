import XCTest
@testable import TurtleGitCore

final class FinderCacheServiceRuntimeTests:XCTestCase {
    @MainActor func awaitCache(_ condition:@escaping ()->Bool) async throws {
        for _ in 0..<1000 { if condition() { return };try await Task.sleep(nanoseconds:10_000_000) }
        XCTFail("Cache service timeout")
    }
    @MainActor func testRestoredEventsReplacementFailureAndShutdown() async throws {
        let folder=try FinderServicePermissionStoreTests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let provider=FinderServicePermissionStoreTests.Provider()
        let permissions=try FinderServicePermissionStore(url:folder.appendingPathComponent("private/grants.json"),provider:provider)
        let cacheURL=folder.appendingPathComponent("shared/status.json"),cache=FinderSnapshotStore(url:cacheURL)
        let first=folder.appendingPathComponent("first"),second=folder.appendingPathComponent("second")
        for root in [first,second] {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let repo=GitRepository(root:root);_ = try await repo.run(["init","-b","main"])
            _ = try await repo.run(["config","user.name","Service QA"]);_ = try await repo.run(["config","user.email","service@example.invalid"])
            try Data("baseline\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"])
            _ = try await repo.run(["-c","commit.gpgsign=false","-c","core.hooksPath=/dev/null","commit","-m","baseline"])
        }
        func request(_ root:URL,_ id:UUID) -> FinderServiceAuthorization {
            FinderServiceAuthorization(grants:[FinderServiceWatchGrant(id:id,bookmark:Data(("TRANSFER:"+root.path).utf8),repositoryComponents:[])])
        }
        let firstID=UUID(),secondID=UUID()
        _ = try permissions.install(request(first,firstID),transfer:provider)
        var notifications=0
        let runtime=FinderCacheServiceRuntime(permissions:permissions,cache:cache,notify:{ notifications += 1 })
        try runtime.start();try await awaitCache { notifications>0 }
        XCTAssertTrue(runtime.failures.isEmpty)
        try Data("external edit\n".utf8).write(to:first.appendingPathComponent("file"))
        try await awaitCache { (try? JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:cacheURL)))?.states[first.appendingPathComponent("file").path] == .modified }
        let previous=try Data(contentsOf:permissions.url);provider.rejectPersistence=true
        do { try await runtime.replace(request(second,secondID),transfer:provider);XCTFail("Rejected permission was installed") } catch {}
        XCTAssertEqual(try Data(contentsOf:permissions.url),previous);XCTAssertTrue(runtime.running)
        provider.rejectPersistence=false
        try await runtime.replace(request(second,secondID),transfer:provider)
        try await awaitCache { (try? JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:cacheURL)))?.roots.contains(second.path)==true }
        let snapshot=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:cacheURL))
        XCTAssertFalse(snapshot.roots.contains(first.path));XCTAssertTrue(runtime.failures.isEmpty)
        await runtime.shutdown();let bytes=try Data(contentsOf:cacheURL),count=notifications
        try Data("after shutdown\n".utf8).write(to:second.appendingPathComponent("file"))
        try await Task.sleep(nanoseconds:600_000_000)
        XCTAssertEqual(try Data(contentsOf:cacheURL),bytes);XCTAssertEqual(notifications,count)
        XCTAssertEqual(provider.starts,provider.stops)
    }
}
