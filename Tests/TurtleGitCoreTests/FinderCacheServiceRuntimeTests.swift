import XCTest
@testable import TurtleGitCore

final class FinderCacheServiceRuntimeTests:XCTestCase {
    @MainActor func awaitCache(_ condition:@escaping ()->Bool) async throws {
        for _ in 0..<1000 { if condition() { return };try await Task.sleep(nanoseconds:10_000_000) }
        XCTFail("Cache service timeout")
    }
    func testDiagnosticSchemasRejectUnknownVersionsDuplicatesAndInvalidLegacyIDs() throws {
        let id = UUID(), date = Date(timeIntervalSinceReferenceDate: 100)
        let original = FinderCacheServiceReport(running: true, roots: [.init(id: id, refreshing: true, lastPublication: date, failure: "watch unavailable")], cleanupFailures: [UUID().uuidString: "cleanup unavailable"], cacheSave: false, cacheFailure: "warm archive unavailable")
        let decoded = try FinderCacheServiceReport.decode(JSONEncoder().encode(original))
        XCTAssertEqual(decoded.roots.first?.failure, "watch unavailable"); XCTAssertEqual(decoded.roots.first?.lastPublication, date)
        XCTAssertTrue(decoded.roots.first?.refreshing == true); XCTAssertEqual(decoded.cleanupFailures.count, 1)
        XCTAssertEqual(decoded.cacheSave, false); XCTAssertEqual(decoded.cacheFailure, "warm archive unavailable")
        var oldReply = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        oldReply.removeValue(forKey: "cacheSave"); oldReply.removeValue(forKey: "cacheFailure")
        let oldDecoded = try FinderCacheServiceReport.decode(JSONSerialization.data(withJSONObject: oldReply))
        XCTAssertNil(oldDecoded.cacheSave); XCTAssertNil(oldDecoded.cacheFailure)
        let duplicate = FinderCacheServiceReport(running: true, roots: [.init(id: id), .init(id: id)])
        XCTAssertThrowsError(try FinderCacheServiceReport.decode(JSONEncoder().encode(duplicate)))
        let legacy = try FinderCacheServiceReport.decode(JSONEncoder().encode([id.uuidString: "permission unavailable"]))
        XCTAssertTrue(legacy.legacy); XCTAssertEqual(legacy.roots.first?.id, id)
        XCTAssertThrowsError(try FinderCacheServiceReport.decode(Data("{\"bad-id\":\"failure\"}".utf8)))
        var version = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]); version["version"] = 99
        XCTAssertThrowsError(try FinderCacheServiceReport.decode(JSONSerialization.data(withJSONObject: version)))
        XCTAssertThrowsError(try FinderCacheServiceReport.decode(Data(repeating: 32, count: 16_777_217)))
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
        XCTAssertEqual(runtime.report.roots.map(\.id), [firstID])
        XCTAssertNotNil(runtime.report.roots.first?.lastPublication)
        XCTAssertGreaterThan(runtime.activitySnapshot.cachedDirectories,0)
        XCTAssertGreaterThan(runtime.activitySnapshot.watchedPaths,0)
        XCTAssertTrue(runtime.activitySnapshot.lines.contains { $0.hasPrefix("Updated path:") })
        let report = try FinderCacheServiceReport.decode(JSONEncoder().encode(runtime.report))
        XCTAssertTrue(report.running); XCTAssertFalse(report.legacy)
        XCTAssertEqual(report.roots.first?.id, firstID)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("bookmark"))
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
        XCTAssertEqual(runtime.report.roots.map(\.id), [secondID]); XCTAssertNotNil(runtime.report.roots.first?.lastPublication)
        await runtime.shutdown(); XCTAssertFalse(runtime.report.running); XCTAssertFalse(runtime.report.roots.contains { $0.refreshing })
        XCTAssertFalse(FinderSnapshot.readLive(from:cacheURL)?.roots.contains(second.path) == true)
        let bytes=try Data(contentsOf:cacheURL),count=notifications
        try Data("after shutdown\n".utf8).write(to:second.appendingPathComponent("file"))
        try await Task.sleep(nanoseconds:600_000_000)
        XCTAssertEqual(try Data(contentsOf:cacheURL),bytes);XCTAssertEqual(notifications,count)
        XCTAssertEqual(provider.starts,provider.stops)
    }
    @MainActor private func repository(_ root:URL) async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=GitRepository(root:root)
        _ = try await repository.run(["init","-b","main"])
        _ = try await repository.run(["config","user.name","Cache lifecycle QA"])
        _ = try await repository.run(["config","user.email","cache-lifecycle@example.invalid"])
        try Data("baseline\n".utf8).write(to:root.appendingPathComponent("file"))
        try await repository.stage(["file"])
        _ = try await repository.run(["-c","commit.gpgsign=false","-c","core.hooksPath=/dev/null","commit","-m","baseline"])
    }
    @MainActor func testDisabledWarmCacheRestartsFreshAndShutdownPreservesOtherLivePublisher() async throws {
        let folder=try FinderServicePermissionStoreTests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let provider=FinderServicePermissionStoreTests.Provider(),root=folder.appendingPathComponent("repo"),other=folder.appendingPathComponent("other")
        try await repository(root)
        let permissions=try FinderServicePermissionStore(url:folder.appendingPathComponent("private/grants.json"),provider:provider),id=UUID()
        let request=FinderServiceAuthorization(grants:[.init(id:id,bookmark:Data(("TRANSFER:"+root.path).utf8),repositoryComponents:[])])
        _ = try permissions.install(request,transfer:provider)
        let grants=try Data(contentsOf:permissions.url),cache=FinderSnapshotStore(url:folder.appendingPathComponent("shared/status.json"))
        try cache.setPersistence(.init(cacheSave:false))
        let otherStore=FinderSnapshotStore(url:cache.url),otherSession=try otherStore.startSession()
        let otherTicket=try otherStore.begin(root:other,session:otherSession)
        XCTAssertTrue(try otherStore.publish(otherTicket,snapshots:[.init(roots:[other.path],states:[other.path:.normal])]).published)
        let overlappingTicket=try otherStore.begin(root:root,session:otherSession)
        XCTAssertTrue(try otherStore.publish(overlappingTicket,snapshots:[.init(roots:[root.path],states:[root.path:.added,root.appendingPathComponent("file").path:.added])]).published)
        let first=FinderCacheServiceRuntime(permissions:permissions,cache:cache)
        do {
            try first.start();try await awaitCache { first.report.roots.first?.lastPublication != nil }
            XCTAssertEqual(first.report.cacheSave,false);XCTAssertNil(first.report.cacheFailure)
            XCTAssertEqual(FinderSnapshot.readLive(from:cache.url)?.states[root.appendingPathComponent("file").path],.normal)
            XCTAssertFalse(FileManager.default.fileExists(atPath:cache.warmURL.path))
        } catch { await first.shutdown();_ = try? otherStore.endSession(otherSession);throw error }
        await first.shutdown()
        XCTAssertEqual(FinderSnapshot.readLive(from:cache.url)?.states[root.appendingPathComponent("file").path],.added)
        XCTAssertTrue(FinderSnapshot.readLive(from:cache.url)?.roots.contains(other.path)==true)
        XCTAssertEqual(try Data(contentsOf:permissions.url),grants)
        try Data("changed while stopped\n".utf8).write(to:root.appendingPathComponent("file"))
        let reopened=FinderSnapshotStore(url:cache.url),second=FinderCacheServiceRuntime(permissions:permissions,cache:reopened)
        do {
            try second.start();try await awaitCache { second.report.roots.first?.lastPublication != nil }
            XCTAssertEqual(second.report.cacheSave,false)
            XCTAssertEqual(FinderSnapshot.readLive(from:cache.url)?.states[root.appendingPathComponent("file").path],.modified)
            XCTAssertFalse(FileManager.default.fileExists(atPath:cache.warmURL.path))
        } catch { await second.shutdown();_ = try? otherStore.endSession(otherSession);throw error }
        await second.shutdown();_ = try otherStore.endSession(otherSession)
        XCTAssertFalse(FinderSnapshot.readLive(from:cache.url)?.roots.contains(other.path)==true)
        XCTAssertEqual(try Data(contentsOf:permissions.url),grants)
        XCTAssertEqual(provider.starts,provider.stops)
    }
    @MainActor func testWarmFailureAndPolicyRetryKeepPublishedBadgesAndPrivateGrants() async throws {
        let folder=try FinderServicePermissionStoreTests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let provider=FinderServicePermissionStoreTests.Provider(),root=folder.appendingPathComponent("repo")
        try await repository(root)
        let permissions=try FinderServicePermissionStore(url:folder.appendingPathComponent("private/grants.json"),provider:provider),id=UUID()
        _ = try permissions.install(.init(grants:[.init(id:id,bookmark:Data(("TRANSFER:"+root.path).utf8),repositoryComponents:[])]),transfer:provider)
        let grants=try Data(contentsOf:permissions.url),cache=FinderSnapshotStore(url:folder.appendingPathComponent("shared/status.json"))
        try FileManager.default.createDirectory(at:cache.warmURL,withIntermediateDirectories:true)
        let runtime=FinderCacheServiceRuntime(permissions:permissions,cache:cache)
        do {
            try runtime.start();try await awaitCache { runtime.report.roots.first?.lastPublication != nil }
            XCTAssertNotNil(runtime.report.cacheFailure);XCTAssertNil(runtime.report.roots.first?.failure)
            XCTAssertEqual(FinderSnapshot.readLive(from:cache.url)?.states[root.appendingPathComponent("file").path],.normal)
            // The requested false policy is saved before its failed cleanup;
            // existing readers/badges and receiver-private permissions survive.
            XCTAssertThrowsError(try cache.setPersistence(.init(cacheSave:false)))
            runtime.reloadCachePolicy()
            XCTAssertEqual(runtime.report.cacheSave,false);XCTAssertNotNil(runtime.report.cacheFailure)
            XCTAssertEqual(FinderSnapshot.readLive(from:cache.url)?.states[root.appendingPathComponent("file").path],.normal)
            XCTAssertEqual(try Data(contentsOf:permissions.url),grants)
            try FileManager.default.removeItem(at:cache.warmURL)
            runtime.refresh()
            try await awaitCache { runtime.report.cacheFailure==nil }
            XCTAssertEqual(runtime.report.cacheSave,false)
            XCTAssertEqual(try Data(contentsOf:permissions.url),grants)
        } catch { await runtime.shutdown();throw error }
        await runtime.shutdown()
        XCTAssertFalse(FinderSnapshot.readLive(from:cache.url)?.roots.contains(root.path)==true)
        XCTAssertEqual(provider.starts,provider.stops)
    }

    @MainActor func testRetryRestoresUnavailableGrantWithoutReplacingRegistry() async throws {
        let folder=try FinderServicePermissionStoreTests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let provider=FinderServicePermissionStoreTests.Provider(),root=folder.appendingPathComponent("repo")
        try await repository(root)
        let permissions=try FinderServicePermissionStore(url:folder.appendingPathComponent("private/grants.json"),provider:provider),id=UUID()
        _ = try permissions.install(.init(grants:[.init(id:id,bookmark:Data(("TRANSFER:"+root.path).utf8),repositoryComponents:[])]),transfer:provider)
        let grants=try Data(contentsOf:permissions.url),cache=FinderSnapshotStore(url:folder.appendingPathComponent("shared/status.json"))
        provider.unavailable.insert(root.path)
        let runtime=FinderCacheServiceRuntime(permissions:permissions,cache:cache)
        do {
            try runtime.start()
            XCTAssertNotNil(runtime.report.roots.first?.failure)
            XCTAssertNil(runtime.report.roots.first?.lastPublication)
            XCTAssertFalse(FinderSnapshot.readLive(from:cache.url)?.roots.contains(root.path)==true)
            provider.unavailable.remove(root.path);runtime.refresh()
            try await awaitCache { runtime.report.roots.first?.lastPublication != nil }
            XCTAssertNil(runtime.report.roots.first?.failure)
            XCTAssertEqual(FinderSnapshot.readLive(from:cache.url)?.states[root.appendingPathComponent("file").path],.normal)
            XCTAssertEqual(try Data(contentsOf:permissions.url),grants)
        } catch { await runtime.shutdown();throw error }
        await runtime.shutdown();XCTAssertEqual(provider.starts,provider.stops)
    }

    @MainActor func testConcurrentShutdownJoinsReaderDrainAndRejectsRestartUntilSettled() async throws {
        @MainActor final class ReaderBarrier {
            var entered=false
            var continuation:CheckedContinuation<Void,Never>?
            func hold() async { entered=true;await withCheckedContinuation { continuation=$0 } }
            func release() { let next=continuation;continuation=nil;next?.resume() }
        }
        let folder=try FinderServicePermissionStoreTests().folder()
        defer { try? FileManager.default.removeItem(at:folder) }
        let provider=FinderServicePermissionStoreTests.Provider(),root=folder.appendingPathComponent("repo")
        try await repository(root)
        let permissions=try FinderServicePermissionStore(url:folder.appendingPathComponent("private/grants.json"),provider:provider),id=UUID()
        let request=FinderServiceAuthorization(grants:[.init(id:id,bookmark:Data(("TRANSFER:"+root.path).utf8),repositoryComponents:[])])
        _ = try permissions.install(request,transfer:provider)
        let cache=FinderSnapshotStore(url:folder.appendingPathComponent("shared/status.json")),runtime=FinderCacheServiceRuntime(permissions:permissions,cache:cache),barrier=ReaderBarrier()
        do {
            try runtime.start();try await awaitCache { runtime.report.roots.first?.lastPublication != nil }
            let grants=try Data(contentsOf:permissions.url)
            runtime.collectionOverride = { repository,access,token in
                let result=try await repository.collectFinderRepository(authorizedRoot:access.lease.url,additionalAuthorizedRoots:access.additionalLeases.map(\.url),cancellation:token)
                // Deliberately cancellation-resistant: the service must join the
                // reader's actual settlement, not merely its cancellation signal.
                await barrier.hold();return result
            }
            runtime.refresh(id);try await awaitCache { barrier.entered }
            var firstDone=false,secondStarted=false,secondDone=false
            let first=Task { await runtime.shutdown();firstDone=true }
            try await awaitCache { !runtime.running }
            let second=Task { secondStarted=true;await runtime.shutdown();secondDone=true }
            try await awaitCache { secondStarted }
            XCTAssertFalse(firstDone);XCTAssertFalse(secondDone)
            XCTAssertThrowsError(try runtime.start())
            do { try await runtime.replace(request,transfer:provider);XCTFail("Replaced grants while shutdown was draining") } catch FinderCacheServiceFailure.transitioning {} catch { throw error }
            XCTAssertEqual(try Data(contentsOf:permissions.url),grants)
            XCTAssertEqual(FinderSnapshot.readLive(from:cache.url)?.states[root.appendingPathComponent("file").path],.normal)
            barrier.release();await first.value;await second.value
            XCTAssertTrue(firstDone);XCTAssertTrue(secondDone)
            XCTAssertFalse(FinderSnapshot.readLive(from:cache.url)?.roots.contains(root.path)==true)
            runtime.collectionOverride=nil
            try runtime.start();try await awaitCache { runtime.report.roots.first?.lastPublication != nil }
            XCTAssertEqual(FinderSnapshot.readLive(from:cache.url)?.states[root.appendingPathComponent("file").path],.normal)
        } catch { barrier.release();await runtime.shutdown();throw error }
        await runtime.shutdown();XCTAssertEqual(provider.starts,provider.stops)
    }

    @MainActor func testShellQueriesStayAuthorizedAndBlockedReadersCannotPublishAfterPolicyChange() async throws {
        @MainActor final class Reader {
            var calls=0
            var hold=false
            var entered=false
            var continuation:CheckedContinuation<Void,Never>?
            func wait() async { entered=true;await withCheckedContinuation {continuation=$0} }
            func release(){let value=continuation;continuation=nil;value?.resume()}
        }
        let folder=try FinderServicePermissionStoreTests().folder()
        defer{try? FileManager.default.removeItem(at:folder)}
        let provider=FinderServicePermissionStoreTests.Provider(),root=folder.appendingPathComponent("repo")
        try await repository(root)
        let permissions=try FinderServicePermissionStore(url:folder.appendingPathComponent("private/grants.json"),provider:provider),id=UUID()
        _ = try permissions.install(.init(grants:[.init(id:id,bookmark:Data(("TRANSFER:"+root.path).utf8),repositoryComponents:[])]),transfer:provider)
        let originalGrants=try Data(contentsOf:permissions.url),cache=FinderSnapshotStore(url:folder.appendingPathComponent("shared/status.json"))
        let runtime=FinderCacheServiceRuntime(permissions:permissions,cache:cache),reader=Reader()
        var blocked=true,policy=FinderStatusPolicy(cacheMode:.shell,blockStatus:true)
        runtime.statusBlocked={_ in blocked};runtime.readStatusPolicy={policy}
        runtime.collectionOverride={_,_,_ in
            reader.calls += 1
            if reader.hold {await reader.wait()}
            let value=FinderSnapshot(roots:[root.path],states:[root.appendingPathComponent("file").path:.modified])
            return FinderRepositoryCollection(root:root,bare:false,entries:[],branch:"main",conflictIsRebase:false,submodules:[],metadata:.init(),watchDirectories:[],snapshots:[value],failures:[:])
        }
        do {
            try runtime.start()
            try runtime.refreshObserved([root.appendingPathComponent("file").path])
            // An unavailable scheduler retains pending work; no Git reader runs.
            try await Task.sleep(nanoseconds:300_000_000)
            XCTAssertEqual(reader.calls,0);XCTAssertNil(runtime.report.roots.first?.lastPublication)
            XCTAssertThrowsError(try runtime.refreshObserved(["relative/path"]))
            XCTAssertThrowsError(try runtime.refreshObserved(Array(repeating:root.path,count:129)))
            blocked=false;runtime.operationStateChanged()
            try await awaitCache {runtime.report.roots.first?.lastPublication != nil}
            XCTAssertEqual(runtime.report.roots.first?.policyIdentity,policy.identity)
            let before=reader.calls
            try runtime.refreshObserved([folder.appendingPathComponent("unauthorized/file").path])
            try await Task.sleep(nanoseconds:300_000_000)
            XCTAssertEqual(reader.calls,before)
            try runtime.refreshObserved([root.appendingPathComponent("file").path])
            try await awaitCache {reader.calls>before && runtime.report.roots.first?.refreshing == false}
            reader.hold=true;runtime.refresh(id)
            try await awaitCache {reader.entered}
            blocked=true;runtime.operationStateChanged()
            policy=FinderStatusPolicy(cacheMode:.shellExtended,caseSensitive:false,blockStatus:true)
            try cache.setStatusPolicy(policy);runtime.operationStateChanged()
            XCTAssertTrue(try cache.readLive().overlayPolicies.isEmpty)
            reader.hold=false;reader.release()
            try await awaitCache {runtime.report.roots.first?.refreshing == false}
            XCTAssertTrue(try cache.readLive().overlayPolicies.isEmpty,"Retired reader restored old-policy badges")
            blocked=false;runtime.operationStateChanged()
            try await awaitCache {(try? cache.readLive().overlayPolicies[root.path]?.identity)==policy.identity}
            XCTAssertEqual(runtime.report.roots.first?.caseSensitive,false)
            XCTAssertEqual(try Data(contentsOf:permissions.url),originalGrants)
        } catch {reader.release();await runtime.shutdown();throw error}
        await runtime.shutdown();XCTAssertEqual(provider.starts,provider.stops)
        XCTAssertFalse(FinderSnapshot.readLive(from:cache.url)?.roots.contains(root.path)==true)
    }

}
