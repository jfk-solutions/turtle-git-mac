// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class GitBlameParentActionTests: XCTestCase {
    func testOriginChoicesHaveByteExactDistinctIdentityWithinSameParent() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let other = "second origin"
        try Data("old\n".utf8).write(to: root.appendingPathComponent(other)); try await repo.stage([other]); _ = try await repo.commit(message: "second origin")
        for value in [path, other] { try Data("changed\n".utf8).write(to: root.appendingPathComponent(value)) }
        try await repo.stage([path, other]); _ = try await repo.commit(message: "two origins")
        let first = try await repo.blame(path: path), second = try await repo.blame(path: other)
        let combined = GitBlameSnapshot(revision: first.revision, path: path, contents: first.contents, encoding: first.encoding, lines: first.lines + second.lines)
        let choices = try await repo.blameHistoryParentComparisons(combined, revision: first.revision)
        XCTAssertEqual(choices.count, 2); XCTAssertEqual(Set(choices.map(\.id)).count, 2)
        XCTAssertEqual(Set(choices.map(\.revision)).count, 1)
        XCTAssertNotEqual(first.revision, before)
        let choice = try XCTUnwrap(choices.first)
        let nfc = "caf\u{e9}", nfd = "cafe\u{301}"
        let left = GitBlameParentComparison(parentNumber: choice.parentNumber, revision: choice.revision, path: nfc, comparison: choice.comparison)
        let right = GitBlameParentComparison(parentNumber: choice.parentNumber, revision: choice.revision, path: nfd, comparison: choice.comparison)
        XCTAssertNotEqual(left.id, right.id)
    }
    func testFilteredMergeParentsKeepActualTargetsButUseSourceOrdinalAndSubject() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        var hashes: [String] = []
        for (branch, content, subject) in [("same", "resolved\n", "same tree"), ("left", "left\n", "left parent with a sufficiently long subject"), ("right", "right\n", "right parent")] {
            _ = try await repo.run(["checkout", "-b", branch, base])
            try Data(content.utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: subject)
            hashes.append(try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines))
        }
        let tree = try await repo.run(["rev-parse", hashes[0] + "^{tree}"]).text.trimmingCharacters(in: .newlines)
        let merge = try await repo.run(["commit-tree", tree, "-p", hashes[0], "-p", hashes[1], "-p", hashes[2], "-m", "merge resolution"]).text.trimmingCharacters(in: .newlines)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: root.appendingPathComponent(path))
        let choices = try await repo.blameParentComparisons(revision: merge, path: path)
        XCTAssertEqual(choices.map(\.parentNumber), [2, 3]); XCTAssertEqual(choices.map(\.revision), [hashes[1], hashes[2]])
        XCTAssertEqual(choices[0].historyMenuTitle(ordinal: 1), "Parent 1: \"left parent with a s...\" (" + hashes[1].prefix(8) + ")")
        XCTAssertEqual(choices[1].historyMenuTitle(ordinal: 2), "Parent 2: \"right parent\" (" + hashes[2].prefix(8) + ")")
        for choice in choices {
            let file = try await repo.comparisonFile(choice.comparison, path: path)
            XCTAssertEqual(file.destination.bytes, Data("resolved\n".utf8))
            XCTAssertEqual(file.base.bytes, Data((choice.parentNumber == 2 ? "left\n" : "right\n").utf8))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
    }
}
