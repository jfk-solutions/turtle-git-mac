import XCTest
@testable import TurtleGitCore

final class ComparisonFileListTests: XCTestCase {
    func testRealComparisonSortsNumericColumnsAndActionOrderWithPathTies() async throws {
        let (root, repo, original) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.dat"))
        try Data("delete one\ndelete two\ndelete three\n".utf8).write(to: root.appendingPathComponent("delete.txt"))
        try await repo.stage(["binary.dat", "delete.txt"]); _ = try await repo.commit(message: "prepare")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["mv", "--", original, "renamed.txt"])
        _ = try await repo.run(["rm", "delete.txt"])
        try Data([0, 9, 8]).write(to: root.appendingPathComponent("binary.dat"))
        try Data("two first\ntwo second\n".utf8).write(to: root.appendingPathComponent("small.txt"))
        try Data((1...12).map { "long addition \($0)\n" }.joined().utf8).write(to: root.appendingPathComponent("large.txt"))
        try await repo.stage(["binary.dat", "small.txt", "large.txt"]); _ = try await repo.commit(message: "compare")
        var options = RevisionDiffOptions(); options.ignoreAllSpace = true
        let snapshot = try await repo.revisionComparison(from: .revision(base), to: .revision("HEAD"), options: options)
        let files = snapshot.files
        let binary = try XCTUnwrap(files.first { $0.path == "binary.dat" })
        XCTAssertTrue(binary.hasStatistics); XCTAssertNil(binary.added)
        XCTAssertEqual(files.sorted(using: [KeyPathComparator(\CommitFile.sortAdded)]).map(\.path), ["binary.dat", "delete.txt", "renamed.txt", "small.txt", "large.txt"])
        XCTAssertEqual(files.sorted(using: [KeyPathComparator(\CommitFile.sortAdded, order: .reverse)]).map(\.path), ["large.txt", "small.txt", "renamed.txt", "delete.txt", "binary.dat"])
        XCTAssertEqual(files.sorted(using: [KeyPathComparator(\CommitFile.sortAction)]).map(\.path), ["large.txt", "small.txt", "binary.dat", "renamed.txt", "delete.txt"])
        XCTAssertEqual(files.sorted(using: [KeyPathComparator(\CommitFile.sortRemoved)]).last?.path, "delete.txt")
        XCTAssertEqual(files.sorted(using: [KeyPathComparator(\CommitFile.sortExtension)]).first?.path, "binary.dat")
        let selected = files.sorted(using: [KeyPathComparator(\CommitFile.sortAdded)]).filter { ["small.txt", "large.txt"].contains($0.path) }
        XCTAssertEqual(ComparisonFileList.clipboard(selected, extended: false), "small.txt\t\nlarge.txt\t\n")
        XCTAssertEqual(ComparisonFileList.clipboard(selected, extended: true), "small.txt\ttxt\tAdded\t2\t0\nlarge.txt\ttxt\tAdded\t12\t0\n")
        let saved = ComparisonFileList.savedList(selected, from: snapshot.from, to: snapshot.to)
        XCTAssertTrue(saved.hasPrefix("Changed files between " + base)); XCTAssertTrue(saved.hasSuffix("\nsmall.txt\nlarge.txt\n"))
    }
    func testRawGitlinkMetadataIsPreservedWhenStatisticsAreAbsent() throws {
        let names = Data("M\0module 雪\npath\0M\0binary.dat\0M\0ignored.txt\0".utf8)
        let raw = Data(":160000 160000 aaaaaaa bbbbbbb M\0module 雪\npath\0:100644 100644 aaaaaaa bbbbbbb M\0binary.dat\0:100644 100644 aaaaaaa bbbbbbb M\0ignored.txt\0".utf8)
        let files = CommitFile.parse(names: names, statistics: Data("-\t-\tbinary.dat\0".utf8), raw: raw)
        XCTAssertTrue(files[0].isSubmodule); XCTAssertFalse(files[0].hasStatistics); XCTAssertEqual(files[0].fileExtension, "")
        XCTAssertTrue(files[1].hasStatistics); XCTAssertFalse(files[1].isSubmodule)
        XCTAssertFalse(files[2].hasStatistics)
    }
}
