import XCTest
import Darwin
@testable import TurtleGitCore

final class FinderCollectionTests:XCTestCase {
    final class WatchRecord:@unchecked Sendable {
        let lock=NSLock();var directories:[URL]=[]
        func capture(_ values:[URL]) { lock.lock();directories=values;lock.unlock() }
    }
    func testLinkedWorktreeRequiresExplicitExternalAdministrationAccess() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitLinkedScope-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:folder) }
        let main=folder.appendingPathComponent("main"),linked=folder.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at:main,withIntermediateDirectories:true)
        let repo=GitRepository(root:main)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Scope QA"),("user.email","scope@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("baseline\n".utf8).write(to:main.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"baseline")
        _ = try await repo.run(["worktree","add","-b","linked",linked.path])
        let worktree=GitRepository(root:linked)
        do { _ = try await worktree.collectFinderRepository(authorizedRoot:linked,additionalAuthorizedRoots:[]);XCTFail("External metadata accepted without grant") } catch RepositoryAccessFailure.repositoryRootOutsidePermission(let path) { XCTAssertTrue(path.contains(".git")) }
        let result=try await worktree.collectFinderRepository(authorizedRoot:linked,additionalAuthorizedRoots:[main.appendingPathComponent(".git")])
        XCTAssertEqual(result.branch,"linked");XCTAssertTrue(result.failures.isEmpty);XCTAssertGreaterThan(result.watchDirectories.count,1)
    }
    func testCancelledReadsNeverFallBackToDefaultsOrPartialChildFailures() async throws {
        let root=URL(fileURLWithPath:"/nonexistent-turtlegit-collector"),repo=GitRepository(root:root,executable:URL(fileURLWithPath:"/usr/bin/false")),token=OperationCancellation();token.cancel()
        let reads:[() async throws -> Void]=[
            { _ = try await repo.collectFinderRepository(authorizedRoot:root,cancellation:token) },
            { _ = try await repo.finderMetadata(cancellation:token) },
            { _ = try await repo.finderSubmoduleSnapshots(authorizedRoot:root,cancellation:token) },
            { _ = try await repo.discoverRoot(cancellation:token) },
            { _ = try await repo.trackedPaths(cancellation:token) }
        ]
        for read in reads { do { try await read();XCTFail("Cancelled read succeeded") } catch OperationCancellationFailure.cancelled {} }
    }
    func indexURL(_ repo:GitRepository) async throws -> URL {
        var bytes=try await repo.run(["rev-parse","--path-format=absolute","--git-path","index"]).stdout
        if bytes.last==10 { bytes.removeLast() };return URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self))
    }
    func testFullRecursiveCollectionPreservesRawIndexesAndContent() async throws {
        let (root,source,innerSource,repo,outer,inner,file)=try await FinderSubmoduleScanTests().fixture()
        defer { for path in [root,source,innerSource] { try? FileManager.default.removeItem(at:path) } }
        let children=[repo,GitRepository(root:outer),GitRepository(root:inner)]
        var indexes:[URL:Data]=[:]
        for child in children { let url=try await indexURL(child);indexes[url]=try Data(contentsOf:url) }
        try Data("outer changed\n".utf8).write(to:outer.appendingPathComponent(file));try Data("inner changed\n".utf8).write(to:inner.appendingPathComponent(file))
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,watch=WatchRecord()
        let result=try await repo.collectFinderRepository(authorizedRoot:root,watchReady:{ watch.capture($0) })
        XCTAssertFalse(result.bare);XCTAssertTrue(result.failures.isEmpty);XCTAssertEqual(result.snapshots.count,3)
        XCTAssertEqual(watch.directories,result.watchDirectories)
        XCTAssertEqual(result.snapshots.first { $0.roots.contains(outer.path) }?.states[outer.appendingPathComponent(file).path],.modified)
        XCTAssertEqual(result.snapshots.first { $0.roots.contains(inner.path) }?.states[inner.appendingPathComponent(file).path],.modified)
        for (url,bytes) in indexes { XCTAssertEqual(bytes,try Data(contentsOf:url),"Collector wrote \(url.path)") }
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(head,after)
        XCTAssertEqual(try Data(contentsOf:inner.appendingPathComponent(file)),Data("inner changed\n".utf8))
    }
    func testOwnedCancellationReapsEveryRootAndChildPhase() async throws {
        let (root,source,innerSource,repo,outer,_,_)=try await FinderSubmoduleScanTests().fixture()
        defer { for path in [root,source,innerSource] { try? FileManager.default.removeItem(at:path) } }
        let phases:[(URL,String)]=[(root,"--is-bare-repository"),(root,"status"),(root,"show-ref"),(root,"config"),(root,"ls-files"),(outer,"--show-toplevel"),(outer,"show-ref"),(outer,"status"),(outer,"-v")]
        func quote(_ value:String) -> String { "'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'" }
        for (slot,phase) in phases.enumerated() {
            let helper=root.appendingPathComponent("collector-helper-\(slot)"),marker=URL(fileURLWithPath:helper.path+".ready")
            let script="""
            #!/bin/sh
            task_location=''; task_previous=''; task_hit=false
            for task_argument in "$@"; do
              if [ "$task_previous" = '-C' ]; then task_location="$task_argument"; fi
              if [ "$task_argument" = \(quote(phase.1)) ]; then task_hit=true; fi
              task_previous="$task_argument"
            done
            if [ "$task_location" = \(quote(phase.0.path)) ] && [ "$task_hit" = true ]; then
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
              /bin/mv "$0.ready.tmp" "$0.ready"
              wait "$task_child"
            fi
            exec \(quote(repo.executable.path)) "$@"
            """
            try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
            let token=OperationCancellation(),slow=GitRepository(root:root,executable:helper)
            let operation=Task { try await slow.collectFinderRepository(authorizedRoot:root,cancellation:token) }
            var pids:[Int32]=[]
            for _ in 0..<500 {
                pids=((try? String(contentsOf:marker)) ?? "").split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
                if pids.count==2 { break };try await Task.sleep(nanoseconds:10_000_000)
            }
            guard pids.count==2 else { token.cancel();_ = await operation.result;XCTFail("No owned phase \(slot): \(phase)");continue }
            XCTAssertTrue(pids.allSatisfy { kill($0,0)==0 },"Owned phase absent: \(pids)")
            let start=Date();token.cancel()
            do { _ = try await operation.value;XCTFail("Cancelled phase became a partial/successful collection") }
            catch is OperationCancellationFailure {} catch is GitCommandCancellationFailure {} catch { XCTFail("Unexpected cancellation: \(error)") }
            XCTAssertLessThan(Date().timeIntervalSince(start),5)
            for _ in 0..<500 { if pids.allSatisfy({ kill($0,0) != 0 }) { break };try await Task.sleep(nanoseconds:10_000_000) }
            XCTAssertTrue(pids.allSatisfy { kill($0,0) != 0 },"Owned phase processes survived: \(pids)")
        }
    }
}
