import XCTest
@testable import TurtleGitCore

final class MergeTests: XCTestCase {
    func testUnrelatedHistoryRetryRequiresExplicitFlagAndCreatesTwoParents() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let left = try await repo.run(["rev-parse", "HEAD"]).stdout
        _ = try await repo.run(["checkout", "--orphan", "unrelated"])
        _ = try await repo.run(["rm", "-rf", "--", "."])
        try Data("right\n".utf8).write(to: root.appendingPathComponent("right")); try await repo.stage(["right"]); _ = try await repo.commit(message: "right")
        _ = try await repo.run(["checkout", "main"])
        var options = MergeOptions(); options.revision = "refs/heads/unrelated"
        do { _ = try await repo.merge(options); XCTFail("Unrelated history merged without explicit retry") } catch is GitFailure {}
        let afterFailure = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(left, afterFailure)
        options.allowUnrelatedHistories = true; _ = try await repo.merge(options)
        let parents = try await repo.run(["rev-list", "--parents", "-n", "1", "HEAD"]).text.split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(parents.count, 3); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("right").path))
    }

    func fixture() async throws -> (URL, GitRepository, String) {
        let (root, repo, path) = try await GitPatchTests().fixture()
        _ = try await repo.run(["checkout", "-b", "feature"])
        try Data("feature\n".utf8).write(to: root.appendingPathComponent("feature.txt"))
        try await repo.stage(["feature.txt"]); _ = try await repo.commit(message: "Feature summary")
        _ = try await repo.run(["tag", "-a", "release", "-m", "release"])
        _ = try await repo.run(["checkout", "main"])
        return (root, repo, path)
    }
    func options() -> MergeOptions { var options = MergeOptions(); options.revision = "refs/heads/feature"; return options }
    func testFastForwardPreservesUnrelatedMixedChangesAndNoCommitDoesNotPreventFastForward() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("index change\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("working change\n".utf8).write(to: root.appendingPathComponent(path))
        let index = try await repo.diff(staged: true), working = try await repo.diff()
        var o = options(); o.noCommit = true; o.fastForwardOnly = true
        _ = try await repo.merge(o)
        let head = try await repo.run(["rev-parse", "HEAD"]).text, target = try await repo.run(["rev-parse", "feature"]).text
        let afterIndex = try await repo.diff(staged: true), afterWorking = try await repo.diff()
        XCTAssertEqual(head, target); XCTAssertEqual(index, afterIndex); XCTAssertEqual(working, afterWorking)
    }
    func testForcedMergeCustomMessageLogAndNoCommitRecoveryState() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await repo.run(["rev-parse", "HEAD"]).text
        var o = options(); o.noFastForward = true; o.noCommit = true; o.message = "Reviewed merge\n\nCustom body"; o.logCount = 3
        _ = try await repo.merge(o)
        let stopped = try await repo.run(["rev-parse", "HEAD"]).text, merge = try await repo.run(["rev-parse", "MERGE_HEAD"]).text, feature = try await repo.run(["rev-parse", "feature"]).text
        let message = try await repo.commitMessageSeed().message
        XCTAssertEqual(original, stopped); XCTAssertEqual(merge, feature); XCTAssertTrue(message.contains("Custom body")); XCTAssertTrue(message.contains("Feature summary"))
        _ = try await repo.run(["merge", "--abort"])
        o.noCommit = false; _ = try await repo.merge(o)
        let parents = try await repo.run(["rev-list", "--parents", "-n", "1", "HEAD"]).text.split(separator: " ")
        let committed = try await repo.run(["show", "--format=%B", "--no-patch", "HEAD"]).text
        XCTAssertEqual(parents.count, 3); XCTAssertTrue(committed.contains("Reviewed merge")); XCTAssertTrue(committed.contains("Feature summary"))
    }
    func testSquashTagLeavesIndexAndSquashMessageWithoutMergeHeadOrCommit() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await repo.run(["rev-parse", "HEAD"]).text
        var o = options(); o.revision = "refs/tags/release"; o.squash = true; o.message = "Hidden editor text"
        _ = try await repo.merge(o)
        let head = try await repo.run(["rev-parse", "HEAD"]).text, index = try await repo.diff(staged: true), message = try await repo.commitMessageSeed().message
        XCTAssertEqual(head, original); XCTAssertTrue(index.contains("feature.txt")); XCTAssertTrue(message.contains("Feature summary")); XCTAssertFalse(message.contains("Hidden editor text"))
        do { _ = try await repo.run(["rev-parse", "--verify", "MERGE_HEAD"]); XCTFail("Squash must not create MERGE_HEAD") } catch is GitFailure {}
    }
    func testValidationRejectsBeforeMutationAndConflictsRemainResolvable() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await repo.run(["rev-parse", "HEAD"]).text
        for revision in ["--abort", "missing", "HEAD\0bad"] {
            var o = options(); o.revision = revision
            do { _ = try await repo.merge(o); XCTFail("Invalid revision accepted") } catch MergeFailure.revision {}
        }
        var o = options(); o.noFastForward = true; o.squash = true
        do { _ = try await repo.merge(o); XCTFail("Incompatible flags accepted") } catch MergeFailure.combination {}
        o = options(); o.strategy = "recursive"; o.strategyOption = "rename-threshold"; o.strategyParameter = "bad"
        do { _ = try await repo.merge(o); XCTFail("Invalid strategy parameter accepted") } catch MergeFailure.parameter {}
        let before = try await repo.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(original, before)
        _ = try await repo.run(["checkout", "feature"])
        try Data("feature conflict\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "feature conflict")
        _ = try await repo.run(["checkout", "main"])
        try Data("local conflict\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "local conflict")
        let local = try await repo.run(["rev-parse", "HEAD"]).text
        o = options(); o.fastForwardOnly = true
        do { _ = try await repo.merge(o); XCTFail("Divergence accepted") } catch is GitFailure {}
        o.fastForwardOnly = false
        do { _ = try await repo.merge(o); XCTFail("Conflict hidden") } catch is GitFailure {}
        let unmerged = try await repo.run(["ls-files", "-u"]).text; XCTAssertFalse(unmerged.isEmpty)
        _ = try await repo.run(["merge", "--abort"])
        let restored = try await repo.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(local, restored)
    }
    func testStrategyOursAndRecursiveTheirsProduceDifferentConflictResults() async throws {
        for strategy in ["ours", "recursive"] {
            let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            _ = try await repo.run(["checkout", "feature"])
            try Data("theirs\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "theirs")
            _ = try await repo.run(["checkout", "main"])
            try Data("ours\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "ours")
            var o = options(); o.strategy = strategy; o.strategyOption = "theirs"; o.strategyParameter = "hidden"
            _ = try await repo.merge(o)
            let contents = try await repo.run(["show", "HEAD:" + path]).text
            let parents = try await repo.run(["rev-list", "--parents", "-n", "1", "HEAD"]).text.split(separator: " ")
            XCTAssertEqual(contents, strategy == "ours" ? "ours\n" : "theirs\n")
            XCTAssertEqual(parents.count, 3)
        }
    }
}
