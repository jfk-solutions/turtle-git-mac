import XCTest
@testable import TurtleGitCore

final class HistoryReferenceLabelTests: XCTestCase {
    func testPairedAndSingleRemoteNamesKeepCanonicalReferences() {
        let refs = [RevisionReference(name: "refs/heads/main", isCurrent: true), RevisionReference(name: "refs/remotes/origin/main"), RevisionReference(name: "refs/tags/release")]
        let context = HistoryReferenceContext(remotes: ["origin"], tracking: ["main": .init(remote: "origin", branch: "main")])
        let plain = context.labels(refs)
        XCTAssertEqual(plain.map(\.text), ["main", "origin/main", "release"])
        XCTAssertEqual(plain.map(\.hasTracking), [true, true, false])
        let symbolized = context.labels(refs, symbolize: true)
        XCTAssertEqual(symbolized.map(\.text), ["main", "/≡", "release"])
        XCTAssertTrue(symbolized[1].singleRemote); XCTAssertTrue(symbolized[1].sameName)
        XCTAssertEqual(symbolized.map(\.reference), refs)
        let multi = HistoryReferenceContext(remotes: ["origin", "backup"], tracking: context.tracking).labels(refs, symbolize: true)
        XCTAssertEqual(multi[1].text, "origin/≡"); XCTAssertFalse(multi[1].singleRemote)
        XCTAssertEqual(context.labels(refs, visibility: [.remoteBranches], symbolize: true).map(\.text), ["/main"])
        XCTAssertTrue(context.labels(refs, visibility: [.localBranches])[0].hasTracking)
    }
    func testSharedUpstreamPairOrderMissingUpstreamAndPrefixBoundaries() {
        let refs = [RevisionReference(name: "refs/heads/a"), RevisionReference(name: "refs/heads/b"), RevisionReference(name: "refs/remotes/origin/topic"), RevisionReference(name: "refs/remotes/original/topic")]
        let context = HistoryReferenceContext(remotes: ["origin"], tracking: ["a": .init(remote: "origin", branch: "topic"), "b": .init(remote: "origin", branch: "topic")])
        let labels = context.labels(refs, symbolize: true)
        XCTAssertEqual(labels.map(\.text), ["a", "/topic", "b", "/topic", "original/topic"])
        XCTAssertTrue(labels[1].singleRemote); XCTAssertFalse(labels[1].sameName)
        let missing = context.labels([refs[0]], symbolize: true)
        XCTAssertEqual(missing.map(\.text), ["a"]); XCTAssertTrue(missing[0].hasTracking)
        XCTAssertEqual(context.labels([refs[2], refs[0]], symbolize: true).map(\.text), ["/topic", "a"], "Only later co-located remote refs pair upstream")
    }
    func testIncompleteTrackingAndDotRemoteDoNotInventRemoteRefs() {
        let refs = [RevisionReference(name: "refs/heads/main"), RevisionReference(name: "refs/notes/commits")]
        for tracking in [HistoryBranchTracking(remote: "", branch: "main"), .init(remote: "origin", branch: "")] {
            XCTAssertFalse(HistoryReferenceContext(tracking: ["main": tracking]).labels(refs)[0].hasTracking)
        }
        let local = HistoryReferenceContext(tracking: ["main": .init(remote: ".", branch: "main")]).labels(refs, symbolize: true)
        XCTAssertEqual(local.map(\.text), ["main", "refs/notes/commits"]); XCTAssertTrue(local[0].hasTracking)
        XCTAssertTrue(HistoryReferenceContext().labels(refs, visibility: []).isEmpty)
    }
    func testRealConfigContextReadPreservesRepositoryBytes() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["remote", "add", "origin", root.path])
        for (key, value) in [("branch.main.remote", "origin"), ("branch.main.merge", "refs/heads/main"), ("branch.雪/topic.remote", "origin"), ("branch.雪/topic.merge", "refs/heads/other"), ("branch.local.remote", "."), ("branch.local.merge", "refs/tags/tag  ")] { _ = try await repo.run(["config", key, value]) }
        let paths = [".git/HEAD", ".git/index", ".git/config", path], before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let context = try await repo.historyReferenceContext()
        XCTAssertEqual(context.remotes, ["origin"])
        XCTAssertEqual(context.tracking["main"], .init(remote: "origin", branch: "main"))
        XCTAssertEqual(context.tracking["雪/topic"], .init(remote: "origin", branch: "other"))
        XCTAssertEqual(context.tracking["local"], .init(remote: ".", branch: "tags/tag"))
        XCTAssertEqual(try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }, before)
    }
}
