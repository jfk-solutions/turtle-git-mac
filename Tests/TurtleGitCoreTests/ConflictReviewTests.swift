import XCTest
@testable import TurtleGitCore

final class ConflictReviewTests: XCTestCase {
    func testDirectoryURLFormAndSymlinkAliasKeepSameConflictOwner() async throws {
        let (root,repo,path) = try await ConflictResolutionTests().fixture(deletedMine: true)
        defer { try? FileManager.default.removeItem(at:root) }
        let plain = GitRepository(root:URL(fileURLWithPath:root.path,isDirectory:false))
        let details = try await plain.deleteConflictDetails(path:path)
        XCTAssertEqual(details.entry.path,path)
        let alias = root.deletingLastPathComponent().appendingPathComponent("TurtleGitAlias-"+UUID().uuidString)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root)
        defer { try? FileManager.default.removeItem(at:alias) }
        let linked = GitRepository(root:URL(fileURLWithPath:alias.path,isDirectory:false))
        let comparison = try await linked.conflictBaseComparison(details.entry)
        XCTAssertEqual(comparison.document.base.text,"base\n")
        let before = try await repo.run(["ls-files","--stage","-z"]).stdout
        let after = try await linked.run(["ls-files","--stage","-z"]).stdout
        XCTAssertEqual(before,after)
    }
    func testDeleteReviewPreCancellationRejectsEveryEntryPointWithoutIndexOrFileWrites() async throws {
        let (root,repo,path) = try await ConflictResolutionTests().fixture(deletedMine: true)
        defer { try? FileManager.default.removeItem(at:root) }
        let details=try await repo.deleteConflictDetails(path:path),index=try Data(contentsOf:root.appendingPathComponent(".git/index")),file=try Data(contentsOf:root.appendingPathComponent(path))
        let token=OperationCancellation();token.cancel()
        let reads: [() async throws -> Void] = [
            { _ = try await repo.deleteConflictDetails(path:path,cancellation:token) },
            { _ = try await repo.deleteConflictChanges(details.entry,cancellation:token) },
            { _ = try await repo.conflictBaseComparison(details.entry,cancellation:token) },
            { _ = try await repo.resolveDeleteConflict(details.entry,deleting:false,cancellation:token) },
            { _ = try await repo.resolveDeleteConflict(details.entry,deleting:true,cancellation:token) }
        ]
        for read in reads { do { try await read();XCTFail("Cancelled conflict review accepted") } catch OperationCancellationFailure.cancelled {} }
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),file)
    }
    func testBaseComparisonEditsOnlyWorkingContentAndRetainsCapturedIndexStages() async throws {
        let (root,repo,path) = try await ConflictResolutionTests().fixture(deletedMine:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let entries=try await repo.conflicts();let entry=try XCTUnwrap(entries.first),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let comparison=try await repo.conflictBaseComparison(entry)
        XCTAssertEqual(comparison.document.base.text,"base\n");XCTAssertEqual(comparison.document.destination.text,"theirs\n")
        XCTAssertEqual(comparison.document.destination.path,path);XCTAssertEqual(comparison.snapshot.root.path,root.path)
        let saved=try await repo.saveConflictBaseComparison(entry,document:comparison.document,text:"reviewed\n")
        XCTAssertEqual(saved.destination.text,"reviewed\n");XCTAssertEqual(saved.base.bytes,comparison.document.base.bytes)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(path)),"reviewed\n")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let reload=try await repo.conflictBaseComparison(entry);XCTAssertEqual(reload.document.destination.text,"reviewed\n")
        try Data("external edit\n".utf8).write(to:root.appendingPathComponent(path))
        do { _ = try await repo.saveConflictBaseComparison(entry,document:saved,text:"stale overwrite\n");XCTFail("Accepted replaced working bytes") } catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(path)),"external edit\n")
        _ = try await repo.resolveDeleteConflict(entry,deleting:false)
        do { _ = try await repo.saveConflictBaseComparison(entry,document:saved,text:"resolved overwrite\n");XCTFail("Accepted resolved stages") } catch ResolveFailure.stale {}
        do { _ = try await repo.conflictBaseComparison(entry);XCTFail("Reload accepted resolved stages") } catch ResolveFailure.stale {}
    }
    func testOrdinaryThreeStageBaseComparisonRetainsRealStageOneAndRejectsGitlinks() async throws {
        let (root,repo,path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let entries=try await repo.conflicts();let entry=try XCTUnwrap(entries.first),value=try await repo.conflictBaseComparison(entry)
        XCTAssertEqual(value.document.base.text,"base\n");XCTAssertTrue(value.document.destination.text!.contains("<<<<<<< HEAD"))
        XCTAssertEqual(value.document.base.revision,.revision(entry.stages.first(where:{$0.number == 1})!.object))
        XCTAssertEqual(value.document.destination.path,path)
        let (parent,source,module,_,modulePath)=try await ConflictResolutionTests().submoduleFixture(initialized:false)
        defer { try? FileManager.default.removeItem(at:parent);try? FileManager.default.removeItem(at:source) }
        let links=try await module.conflicts(paths:[modulePath]);let linked=try XCTUnwrap(links.first)
        do { _ = try await module.conflictBaseComparison(linked);XCTFail("Compared gitlink as text") } catch DeleteConflictFailure.unsupported {}
    }
    func testSubmodulePreCancellationDoesNotBecomeUnavailableMetadata() async throws {
        let (root,source,repo,_,path)=try await ConflictResolutionTests().submoduleFixture(initialized:true)
        defer { try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:source) }
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),token=OperationCancellation();token.cancel()
        do { _ = try await repo.submoduleConflictDetails(path:path,cancellation:token);XCTFail("Cancellation became unavailable side") } catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
}
