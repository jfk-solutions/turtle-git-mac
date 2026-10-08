import XCTest
@testable import TurtleGitCore

final class ReferenceLogDiffTests: XCTestCase {
    func testParentCombinedAndExtraMergeDiffsRetainBytesAndRepository() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["branch", "side"])
        try Data("main\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "main café")
        _ = try await repo.run(["checkout", "side"])
        try Data("side\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "side 🐢")
        _ = try await repo.run(["checkout", "main"]); _ = try await repo.run(["merge", "--no-commit", "side"], successfulExitCodes: 0...1)
        try Data("resolution\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "manual merge")
        let merge = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), bytes = try Data(contentsOf: root.appendingPathComponent(path))
        let parents = try await repo.referenceLogDiffParents(merge); XCTAssertEqual(parents.map(\.subject), ["main café", "side 🐢"])
        for (number, deleted) in [(1, "main"), (2, "side")] {
            let diff = try await repo.referenceLogUnifiedDiff(merge, mode: .parent(number))
            let text = String(decoding: diff.bytes, as: UTF8.self)
            XCTAssertTrue(text.contains("-" + deleted + "\n+resolution")); XCTAssertFalse(diff.noExtraChanges)
        }
        let all = try await repo.referenceLogUnifiedDiff(merge, mode: .allParents)
        XCTAssertTrue(String(decoding: all.bytes, as: UTF8.self).contains("-main")); XCTAssertTrue(String(decoding: all.bytes, as: UTF8.self).contains("-side"))
        let combined = try await repo.referenceLogUnifiedDiff(merge, mode: .onlyMergedFiles)
        XCTAssertTrue(String(decoding: combined.bytes, as: UTF8.self).contains("diff --combined"))
        let extra = try await repo.referenceLogUnifiedDiff(merge, mode: .extraChanges)
        XCTAssertFalse(extra.noExtraChanges); XCTAssertTrue(String(decoding: extra.bytes, as: UTF8.self).contains("diff --cc"))
        let pair = try await repo.referenceLogUnifiedDiff(from: base, to: merge)
        XCTAssertTrue(String(decoding: pair, as: UTF8.self).contains("+resolution"))
        let identical = try await repo.referenceLogUnifiedDiff(from: merge, to: merge); XCTAssertTrue(identical.isEmpty)
        for mode in [ReferenceLogDiffMode.parent(0), .parent(3)] {
            do { _ = try await repo.referenceLogUnifiedDiff(merge, mode: mode); XCTFail("Invalid parent accepted") } catch is RevisionComparisonFailure {}
        }
        do { _ = try await repo.referenceLogUnifiedDiff(base, mode: .parent(1)); XCTFail("Root parent accepted") } catch is RevisionComparisonFailure {}
        do { _ = try await repo.referenceLogUnifiedDiff("--all", mode: .allParents); XCTFail("Option accepted") } catch is GitFailure {}
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(head, afterHead); XCTAssertEqual(refs, afterRefs)
        XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index"))); XCTAssertEqual(config, try Data(contentsOf: root.appendingPathComponent(".git/config"))); XCTAssertEqual(bytes, try Data(contentsOf: root.appendingPathComponent(path)))
    }
}
