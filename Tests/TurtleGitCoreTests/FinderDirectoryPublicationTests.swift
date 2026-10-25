import XCTest
@testable import TurtleGitCore

final class FinderDirectoryPublicationTests:XCTestCase {
    private struct Fixture {
        let directory:URL
        let repository:GitRepository
        let untracked="nested Cafe\u{301} 雪\nrepository"
        let ignored="ignored Cafe\u{301} 雪"
        let literal="literal \\ Cafe\u{301}.txt"
    }
    private func fixture() async throws -> Fixture {
        let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TurtleGitDirectoryPublication-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_TEST_GIT"] ?? "/usr/bin/git")
        let root=directory.appendingPathComponent("repository"),repo=GitRepository(root:root,executable:executable)
        let f=Fixture(directory:directory,repository:repo)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
            try await initialize(repo)
            try Data((f.ignored+"/\n").utf8).write(to:root.appendingPathComponent(".gitignore"))
            try await repo.stage([".gitignore"]);_ = try await repo.commit(message:"baseline")
            for name in [f.untracked,f.ignored] {
                let childRoot=FileTransferPaths.fileURL(root.path+"/"+name)
                try FileManager.default.createDirectory(at:childRoot,withIntermediateDirectories:false)
                let child=GitRepository(root:childRoot,executable:executable)
                try await initialize(child)
                try Data([0,255,10,65]).write(to:childRoot.appendingPathComponent("payload"))
                try await child.stage(["payload"]);_ = try await child.commit(message:"nested baseline")
            }
            try Data([255,0,10]).write(to:FileTransferPaths.fileURL(root.path+"/"+f.literal))
            return f
        } catch {try? FileManager.default.removeItem(at:directory);throw error}
    }
    private func initialize(_ repository:GitRepository) async throws {
        _ = try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Directory publication QA"),("user.email","directory@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeUnicode","false")] {
            _ = try await repository.run(["config",key,value])
        }
    }
    func testRealNestedAndIgnoredRepositoryMarkersPublishWithLiteralIdentityAndPolicy() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.directory)}
        let repo=f.repository,root=repo.root,policy=FinderStatusPolicy()
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let raw=try await repo.run(["status","--porcelain=v1","-z","--untracked-files=all","--ignored"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"]).stdout
        for (code,name) in [("??",f.untracked),("!!",f.ignored)] {
            XCTAssertNotNil(raw.range(of:Data((code+" "+name+"/\0").utf8)),"The real Git directory-marker witness is required")
        }
        let collection=try await repo.collectFinderRepository(authorizedRoot:root,policy:policy)
        XCTAssertTrue(collection.failures.isEmpty)
        XCTAssertTrue(collection.entries.contains {Data($0.path.utf8)==Data((f.untracked+"/").utf8) && $0.state == .untracked},"Application status identity must retain Git's original marker")
        let snapshot=try XCTUnwrap(collection.snapshots.first { $0.roots.contains(root.path) })
        for (name,state) in [(f.untracked,FileState.untracked),(f.ignored,.ignored),(f.literal,.untracked)] {
            let path=root.path+"/"+name
            XCTAssertEqual(snapshot.states[path],state)
            XCTAssertNotNil(snapshot.overlayEntries?[path])
            XCTAssertNil(snapshot.states[path+"/"])
            XCTAssertNil(snapshot.overlayEntries?[path+"/"])
            XCTAssertTrue(snapshot.states.keys.contains {Data($0.utf8)==Data(path.utf8)},"Snapshot must preserve literal UTF-8 spelling")
        }
        XCTAssertEqual(snapshot.states[root.path],.untracked)
        XCTAssertEqual(snapshot.overlayPolicies[root.path]?.identity,policy.identity)
        let store=FinderSnapshotStore(url:f.directory.appendingPathComponent("status.json"))
        try store.configureStatusPolicy(policy:{policy},publish:{},rollback:{})
        let session=try store.startSession();defer {_ = try? store.endSession(session)}
        let ticket=try store.begin(root:root,session:session,policy:policy)
        let result=try store.publish(ticket,snapshots:collection.snapshots)
        XCTAssertTrue(result.published)
        XCTAssertEqual(result.snapshot.states[root.path+"/"+f.untracked],.untracked)
        XCTAssertEqual(result.snapshot.states[root.path+"/"+f.ignored],.ignored)
        XCTAssertEqual(result.snapshot.overlayPolicies[root.path]?.identity,policy.identity)
        XCTAssertEqual(try store.readLive().states[root.path],.untracked)
        let stale=try store.begin(root:root,session:session,policy:policy)
        try store.configureStatusPolicy(policy:{FinderStatusPolicy(cacheMode:.shell)},publish:{},rollback:{})
        XCTAssertFalse(try store.publish(stale,snapshots:collection.snapshots).published,"Directory normalization must not bypass the policy-identity fence")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(after,head);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:FileTransferPaths.fileURL(root.path+"/"+f.literal)),Data([255,0,10]))
    }
    func testOnlyValidUntrackedAndIgnoredDirectoryMarkersAreNormalized() throws {
        let root=FileTransferPaths.fileURL("/literal-repository")
        let names=["Cafe\u{301} 雪\n", "Café 雪\n", "literal \\ name"]
        let entries=names.enumerated().map {offset,name in StatusEntry(path:name+"/",originalPath:nil,index:offset==1 ? "!":"?",worktree:offset==1 ? "!":"?")}
        let snapshot=FinderSnapshot.build(root:root,tracked:[],changes:entries)
        XCTAssertEqual(snapshot.overlayEntries?.count,3)
        for name in names {
            let key=root.path+"/"+name
            XCTAssertNotNil(snapshot.states[key]);XCTAssertNil(snapshot.states[key+"/"])
            XCTAssertTrue(snapshot.states.keys.contains {Data($0.utf8)==Data(key.utf8)})
        }
        XCTAssertEqual(entries.map {Data($0.path.utf8)},names.map {Data(($0+"/").utf8)},"Snapshot construction must not rewrite the original status records")
    }
    func testMalformedAndTrackedTrailingPathsRemainRejectedByPublication() throws {
        let directory=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TurtleGitDirectoryRefusal-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false);defer {try? FileManager.default.removeItem(at:directory)}
        let root=directory.appendingPathComponent("repository"),store=FinderSnapshotStore(url:directory.appendingPathComponent("status.json"))
        let session=try store.startSession();defer {_ = try? store.endSession(session)}
        let invalid=["../escape/","part/../escape/","/outside/","part//leaf/","part/\0leaf/","trailing//","./leaf/"]
        for path in invalid {
            let snapshot=FinderSnapshot.build(root:root,tracked:[],changes:[.init(path:path,originalPath:nil,index:"?",worktree:"?")])
            let ticket=try store.begin(root:root,session:session)
            XCTAssertThrowsError(try store.publish(ticket,snapshots:[snapshot])) {error in
                guard let failure=error as? FinderPublicationFailure,case .invalidUpdate=failure else {return XCTFail("Unexpected refusal: \(error)")}
            }
            XCTAssertNotNil(snapshot.states[root.path+"/"+path],"Malformed input must not be silently repaired")
        }
        let tracked=FinderSnapshot.build(root:root,tracked:[],changes:[.init(path:"tracked/",originalPath:nil,index:" ",worktree:"M")])
        XCTAssertNotNil(tracked.states[root.path+"/tracked/"])
        XCTAssertThrowsError(try store.publish(store.begin(root:root,session:session),snapshots:[tracked]))
    }
}
