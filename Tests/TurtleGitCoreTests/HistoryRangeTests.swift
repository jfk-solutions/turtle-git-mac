import XCTest
@testable import TurtleGitCore

final class HistoryRangeTests: XCTestCase {
    func testDifferenceSymmetricRangesValidateEndpointsAndPreserveRepository() async throws {
        let (root, original, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? original.executable)
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["branch", "side"])
        try Data("main\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "main only")
        let main = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "side"])
        try Data("side\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "side only")
        let side = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["tag", "-a", "main-tag", main, "-m", "range tag"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), bytes = try Data(contentsOf: root.appendingPathComponent(path))
        var options = HistoryOptions(); options.allBranches = true; options.endRevision = "invalid-ignored-end"
        for (range, expected) in [
            (HistoryRevisionRange(from: "side", to: "main-tag"), Set([main])),
            (HistoryRevisionRange(from: "main", to: "side"), Set([side])),
            (HistoryRevisionRange(from: main, to: side, kind: .symmetricDifference), Set([main, side])),
            (HistoryRevisionRange(from: base, to: main), Set([main])),
            (HistoryRevisionRange(from: main, to: base), Set<String>()),
            (HistoryRevisionRange(from: main, to: main, kind: .symmetricDifference), Set<String>())
        ] {
            options.revisionRange = range
            let entries = try await repo.history(options: options)
            XCTAssertEqual(Set(entries.map(\.hash)), expected, range.expression)
        }
        options.revisionRange = HistoryRevisionRange(from: main, to: side, kind: .symmetricDifference); options.paths = [path]
        options.search = "side only"; let filtered = try await repo.history(options: options); XCTAssertEqual(filtered.map(\.hash), [side])
        options.search = ""; options.paths = []; options.limit = 1
        let limited = try await repo.history(options: options); XCTAssertEqual(limited.count, 1)
        for invalid in ["--all", "main..side", "no-such-ref", ""] {
            for range in [HistoryRevisionRange(from: invalid, to: main), HistoryRevisionRange(from: main, to: invalid)] {
                options.revisionRange = range
                do { _ = try await repo.history(options: options); XCTFail("Invalid range endpoint accepted: \(range.expression)") } catch is GitFailure {}
            }
        }
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(head, afterHead); XCTAssertEqual(refs, afterRefs)
        XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index"))); XCTAssertEqual(config, try Data(contentsOf: root.appendingPathComponent(".git/config"))); XCTAssertEqual(bytes, try Data(contentsOf: root.appendingPathComponent(path)))
    }
}
