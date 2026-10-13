import XCTest
@testable import TurtleGitCore

final class ReferenceLogAdvancedTests: XCTestCase {
    func testTransportPresetsTagPeelingMovedNamesHeadAndSVNGuards() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try await repo.referenceLog("HEAD")[0]
        _ = try await repo.run(["tag", "-a", "release", "-m", "release"])
        _ = try await repo.run(["branch", "old", old.hash])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "new"])
        let current = try await repo.referenceLog("HEAD")[0]
        let tag = try await repo.referenceLogTransportRequest(command: .push, entry: old, references: ["refs/heads/main", "refs/tags/release^{}"])
        XCTAssertEqual(tag.source, "refs/tags/release")
        let local = try await repo.referenceLogTransportRequest(command: .push, entry: old, references: ["refs/tags/release", "refs/heads/old"])
        XCTAssertEqual(local.source, "refs/heads/old")
        let moved = try await repo.referenceLogTransportRequest(command: .push, entry: old, references: ["refs/heads/main"])
        XCTAssertEqual(moved.source, old.hash)
        let pull = try await repo.referenceLogTransportRequest(command: .pull, entry: current, references: [])
        XCTAssertNil(pull.source)
        do { _ = try await repo.referenceLogTransportRequest(command: .pull, entry: old, references: []); XCTFail("Old HEAD accepted for Pull") } catch is ReferenceLogFailure {}
        do { _ = try await repo.referenceLogTransportRequest(command: .svnDCommit, entry: current, references: []); XCTFail("Missing SVN metadata accepted") } catch is ReferenceLogFailure {}
        let metadata = root.appendingPathComponent(".git/svn/.metadata")
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: metadata)
        let svn = try await repo.referenceLogTransportRequest(command: .svnDCommit, entry: current, references: [])
        XCTAssertNil(svn.source)
        try Data(old.hash.utf8).write(to: root.appendingPathComponent(".git/MERGE_HEAD"))
        do { _ = try await repo.referenceLogTransportRequest(command: .pull, entry: current, references: []); XCTFail("Merge accepted for Pull") } catch is ReferenceLogFailure {}
    }
    func testCombineMatchesSourceEventPositionsAndRejectsDuplicateCheckoutRows() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["commit","--allow-empty","-m","Middle"])
        _ = try await repo.run(["commit","--allow-empty","-m","Newest"])
        let head = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines), rows = try await repo.referenceLog("HEAD")
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let candidate = try await repo.referenceLogCombineCandidate(snapshot:rows,selected:Set(rows.prefix(2).map(\.id)),expectedHead:head)
        XCTAssertEqual(candidate?.entries.map(\.hash), rows.prefix(2).map(\.hash)); XCTAssertEqual(candidate?.offset,0)
        let sparse = try await repo.referenceLogCombineCandidate(snapshot:rows,selected:[rows[0].id,rows[2].id],expectedHead:head)
        XCTAssertNil(sparse)
        let stale = try await repo.referenceLogCombineCandidate(snapshot:rows,selected:Set(rows.prefix(2).map(\.id)),expectedHead:rows[1].hash)
        XCTAssertNil(stale)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        _ = try await repo.run(["checkout","--detach","HEAD"])
        let duplicate = try await repo.referenceLog("HEAD")
        let rejected = try await repo.referenceLogCombineCandidate(snapshot:duplicate,selected:Set(duplicate.prefix(2).map(\.id)),expectedHead:head)
        XCTAssertNil(rejected)
    }
    func testBisectPresetsMovedReferenceFallbackAndActiveMarkedGuards() async throws {
        let (root,repo,_) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["commit","--allow-empty","-m","Middle"])
        let middle = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["branch","middle",middle])
        _ = try await repo.run(["commit","--allow-empty","-m","Newest"])
        let head = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines), rows = try await repo.referenceLog("HEAD")
        let ids = Set(rows.prefix(2).map(\.id)), refs = [head:["refs/heads/main"],middle:["refs/heads/middle"]]
        let request = try await repo.referenceLogBisectRequest(snapshot:rows,selected:ids,operation:nil,references:refs)
        XCTAssertEqual(request.good,"refs/heads/middle"); XCTAssertEqual(request.bad,"refs/heads/main")
        _ = try await repo.run(["branch","-f","middle",head])
        let moved = try await repo.referenceLogBisectRequest(snapshot:rows,selected:ids,operation:nil,references:refs)
        XCTAssertEqual(moved.good,middle)
        _ = try await repo.startBisect(good:base,bad:head)
        let before = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let middleID = try XCTUnwrap(rows.first { $0.hash == middle }?.id)
        let good = try await repo.referenceLogBisectRequest(snapshot:rows,selected:[middleID],operation:.good,references:refs)
        XCTAssertEqual(good.operation,.good); XCTAssertEqual(good.revisions,[middle])
        do { _ = try await repo.referenceLogBisectRequest(snapshot:rows,selected:ids,operation:.skip,references:refs); XCTFail("Marked selection accepted") }
        catch is ReferenceLogBisectFailure {}
        let after = try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(after,before); XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
}
