import XCTest
@testable import TurtleGitCore

private final class RevertMixedEvents:@unchecked Sendable {
    private let lock=NSLock()
    private var values:[WorkingFileRevertProgress]=[]
    func append(_ value:WorkingFileRevertProgress) {lock.lock();values.append(value);lock.unlock()}
    var snapshot:[WorkingFileRevertProgress] {lock.lock();defer{lock.unlock()};return values}
}

final class WorkingFileRevertMixedTests:XCTestCase {
    private struct Fixture {
        let root:URL,repo:GitRepository,tracked:String,added:String,unknown:String,ignored:String
        let entries:[StatusEntry],working:GitPathMap<Data>,index:Data,head:Data
    }
    private func baseFixture()async throws->(URL,GitRepository,String) {
        // The seed helper creates local history with system Git. All new batch
        // setup, Revert, Retry and assertions use the explicitly selected engine.
        let (root,original,path)=try await GitPatchTests().fixture()
        let git=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? original.executable.path)
        let repository=GitRepository(root:root,executable:git,askpass:nil,diffDetection:original.diffDetection,libgit2Configuration:.init(enabled:false))
        return (root,repository,path)
    }
    private func fixture()async throws->Fixture {
        let (root,repo,path)=try await baseFixture()
        do {
            let added=":(glob)* addition.txt",unknown="unknown 雪\n.txt",ignored="ignored.txt"
            try Data("ignored.txt\nignored-link\n".utf8).write(to:root.appendingPathComponent(".gitignore"))
            try Data("unrelated base\n".utf8).write(to:root.appendingPathComponent("unrelated"))
            try await repo.stage([".gitignore","unrelated"]);_ = try await repo.commit(message:"Mixed Revert base")
            try Data("unrelated staged\n".utf8).write(to:root.appendingPathComponent("unrelated"));try await repo.stage(["unrelated"])
            try Data("tracked staged\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path])
            let working:GitPathMap<Data>=[path:Data([0,255,13,10]),added:Data("added working\n".utf8),unknown:Data("unknown working\n".utf8),ignored:Data("ignored working\n".utf8)]
            for (name,bytes) in working {try bytes.write(to:root.appendingPathComponent(name))}
            try await repo.stage([added])
            let rows=try await repo.status(),lookup=GitPathMap(rows.map{($0.path,$0)},uniquingKeysWith:{_,last in last})
            let entries=try [path,added,unknown,ignored].map{try XCTUnwrap(lookup[$0])}
            let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
            return .init(root:root,repo:repo,tracked:path,added:added,unknown:unknown,ignored:ignored,entries:entries,working:working,index:index,head:head)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private func failed(_ fixture:Fixture,entries:[StatusEntry]?=nil,policy:WorkingFileRevertPolicy,token:OperationCancellation?=nil,events:RevertMixedEvents?=nil)async throws->WorkingFileRevertFailure {
        do {
            let result=try await fixture.repo.revertWorkingFiles(entries ?? fixture.entries,policy:policy,cancellation:token,progress:{event in events?.append(event)})
            for copy in result.trashedFiles {try? FileManager.default.removeItem(at:copy)}
            XCTFail("Mixed unknown pathspec unexpectedly succeeded")
            throw GitFailure(arguments:["test"],code:1,message:"Expected a mixed Revert Git error")
        } catch let failure as WorkingFileRevertFailure {return failure}
    }
    private func assertIndexAndHead(_ fixture:Fixture,file:StaticString=#filePath,line:UInt=#line)async throws {
        XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(".git/index")),fixture.index,file:file,line:line)
        let head=try await fixture.repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(head,fixture.head,file:file,line:line)
        XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent(".git/index.lock").path),file:file,line:line)
    }

    func testMixedTrashFailureRetainsAllRequestedNamesRecoveryAndOriginalIndexOnRetry()async throws {
        let fixture=try await fixture();var copies:[URL]=[]
        defer{for copy in copies{try? FileManager.default.removeItem(at:copy)};try? FileManager.default.removeItem(at:fixture.root)}
        let events=RevertMixedEvents(),failure=try await failed(fixture,policy:.init(),events:events);copies=failure.trashedFiles
        XCTAssertFalse(failure.wasCancelled);XCTAssertTrue(failure.gitError.contains("did not match"))
        XCTAssertTrue(failure.gitError.contains(fixture.ignored));XCTAssertTrue(failure.localizedDescription.contains("remain recoverable"))
        XCTAssertEqual(copies.count,3)
        XCTAssertEqual(Set(try copies.map{try Data(contentsOf:$0)}),Set([fixture.working[fixture.tracked]!,fixture.working[fixture.unknown]!,fixture.working[fixture.ignored]!]))
        for path in [fixture.tracked,fixture.unknown,fixture.ignored] {XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent(path).path))}
        XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(fixture.added)),fixture.working[fixture.added])
        XCTAssertEqual(events.snapshot.filter{$0.finished && $0.step == .recycle}.count,3)
        XCTAssertFalse(events.snapshot.contains{$0.finished && $0.step == .restore})
        try await assertIndexAndHead(fixture)
        let retry=try await fixture.repo.workingFileRevertSelection(fixture.entries)
        XCTAssertEqual(GitPathSet(retry.map(\.path)),GitPathSet(fixture.entries.map(\.path)),"Retry must retain missing unknown/ignored names rather than revert a reduced selection")
        XCTAssertEqual(retry.first{GitReferenceName.equal($0.path,fixture.unknown)}?.state,.untracked)
        XCTAssertEqual(retry.first{GitReferenceName.equal($0.path,fixture.ignored)}?.state,.ignored)
        let again=try await failed(fixture,entries:retry,policy:.init(recycle:false))
        XCTAssertFalse(again.wasCancelled);XCTAssertTrue(again.gitError.contains("did not match"));XCTAssertTrue(again.trashedFiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent(fixture.tracked).path))
        try await assertIndexAndHead(fixture)
    }

    func testNoTrashMixedCohortDoesNotRestoreEarlierVersionedBatchesBeforeUnknownError()async throws {
        let (root,repo,_)=try await baseFixture();defer{try? FileManager.default.removeItem(at:root)}
        let paths=(0..<70).map{String(format:"cohort-%03d.txt",$0)},unknown="zzzz-unknown.txt",added="addition.txt"
        for path in paths {try Data("base\n".utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(paths);_ = try await repo.commit(message:"Large mixed cohort")
        for path in paths {try Data("working\n".utf8).write(to:root.appendingPathComponent(path))}
        try Data("unknown\n".utf8).write(to:root.appendingPathComponent(unknown));try Data("addition\n".utf8).write(to:root.appendingPathComponent(added));try await repo.stage([added,paths[0]])
        let selected=try await repo.status(),index=try Data(contentsOf:root.appendingPathComponent(".git/index")),events=RevertMixedEvents()
        do {
            _ = try await repo.revertWorkingFiles(selected,policy:.init(recycle:false),progress:{events.append($0)})
            XCTFail("Unknown pathspec accepted")
        } catch let failure as WorkingFileRevertFailure {
            XCTAssertFalse(failure.wasCancelled);XCTAssertTrue(failure.trashedFiles.isEmpty);XCTAssertTrue(failure.gitError.contains(unknown))
        }
        for path in paths {XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),Data("working\n".utf8))}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(unknown)),Data("unknown\n".utf8))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(added)),Data("addition\n".utf8))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertFalse(events.snapshot.contains{$0.step == .recycle || $0.step == .restore && $0.finished})
        XCTAssertEqual(GitPathSet(events.snapshot.filter{$0.step == .restore}.map(\.path)),GitPathSet(paths+[unknown]))
    }

    func testRetryRefreshesIgnoredTransitionsAndFailsExplicitlyForLostVersionedIdentity()async throws {
        let fixture=try await fixture();defer{try? FileManager.default.removeItem(at:fixture.root)}
        // A literal ignored transition stays part of the same captured request;
        // unrelated ignored content is not added to that request.
        let extra="ignored-sibling.txt"
        let patterns="ignored.txt\nignored-link\nignored-sibling.txt\nunknown*\n"
        try Data(patterns.utf8).write(to:fixture.root.appendingPathComponent(".gitignore"));try Data("private sibling\n".utf8).write(to:fixture.root.appendingPathComponent(extra))
        let refreshed=try await fixture.repo.workingFileRevertSelection(fixture.entries)
        XCTAssertEqual(GitPathSet(refreshed.map(\.path)),GitPathSet(fixture.entries.map(\.path)))
        XCTAssertEqual(refreshed.first{GitReferenceName.equal($0.path,fixture.unknown)}?.state,.ignored)
        XCTAssertFalse(refreshed.contains{GitReferenceName.equal($0.path,extra)})
        try FileManager.default.removeItem(at:fixture.root.appendingPathComponent(fixture.ignored))
        let absent=try await fixture.repo.workingFileRevertSelection(refreshed)
        XCTAssertTrue(absent.contains{GitReferenceName.equal($0.path,fixture.ignored) && $0.state == .ignored})
        // A former indexed addition deleted after an external unstage has no
        // current row and no unknown/ignored recovery identity to retain.
        try await fixture.repo.unstage([fixture.added]);try FileManager.default.removeItem(at:fixture.root.appendingPathComponent(fixture.added))
        let index=try Data(contentsOf:fixture.root.appendingPathComponent(".git/index"))
        do {_ = try await fixture.repo.workingFileRevertSelection(fixture.entries);XCTFail("Retry silently omitted a lost selected addition")}
        catch let failure as GitFailure {XCTAssertTrue(failure.localizedDescription.contains("no longer available"));XCTAssertTrue(failure.localizedDescription.contains(fixture.added))}
        XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(fixture.tracked)),fixture.working[fixture.tracked])
    }

    func testMixedSymlinksRecycleTheirLinksWithoutFollowingOutsideTargets()async throws {
        let fixture=try await fixture(),outside=fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        var copies:[URL]=[]
        defer{for copy in copies{try? FileManager.default.removeItem(at:copy)};try? FileManager.default.removeItem(at:fixture.root);try? FileManager.default.removeItem(at:outside)}
        try Data("outside unchanged\n".utf8).write(to:outside)
        let names=["unknown-link","ignored-link"]
        for name in names {try FileManager.default.createSymbolicLink(atPath:fixture.root.appendingPathComponent(name).path,withDestinationPath:outside.path)}
        let selected=try await fixture.repo.status().filter{names.contains($0.path) || GitReferenceName.equal($0.path,fixture.tracked)}
        let failure=try await failed(fixture,entries:selected,policy:.init());copies=failure.trashedFiles
        XCTAssertEqual(copies.count,3);XCTAssertTrue(failure.gitError.contains("did not match"))
        let linkCopies=copies.filter{(try? FileManager.default.attributesOfItem(atPath:$0.path)[.type]) as? FileAttributeType == .typeSymbolicLink}
        XCTAssertEqual(linkCopies.count,2)
        for copy in linkCopies {XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:copy.path),outside.path)}
        XCTAssertEqual(try Data(contentsOf:outside),Data("outside unchanged\n".utf8))
        try await assertIndexAndHead(fixture)
    }

    func testMixedCancellationRetainsCompletedTrashWithoutPublishingPreparedIndex()async throws {
        let fixture=try await fixture(),token=OperationCancellation(),events=RevertMixedEvents();var copies:[URL]=[]
        defer{for copy in copies{try? FileManager.default.removeItem(at:copy)};try? FileManager.default.removeItem(at:fixture.root)}
        do {
            _ = try await fixture.repo.revertWorkingFiles(fixture.entries,cancellation:token,progress:{event in events.append(event);if event.finished && event.step == .recycle {token.cancel()}})
            XCTFail("Cancellation was accepted as success")
        } catch let failure as WorkingFileRevertFailure {
            copies=failure.trashedFiles;XCTAssertTrue(failure.wasCancelled);XCTAssertEqual(copies.count,1)
        }
        let recycled=events.snapshot.filter{$0.finished && $0.step == .recycle};XCTAssertEqual(recycled.count,1)
        XCTAssertFalse(events.snapshot.contains{$0.step == .restore})
        let moved=try XCTUnwrap(recycled.first?.path)
        for (path,bytes) in fixture.working where !GitReferenceName.equal(path,moved) {XCTAssertEqual(try Data(contentsOf:fixture.root.appendingPathComponent(path)),bytes)}
        XCTAssertEqual(try Data(contentsOf:try XCTUnwrap(copies.first)),fixture.working[moved])
        try await assertIndexAndHead(fixture)
    }
}
