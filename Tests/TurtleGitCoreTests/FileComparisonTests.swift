import XCTest
@testable import TurtleGitCore

final class FileComparisonTests: XCTestCase {
    func testAlignmentRecoversExactSourcesAndGroupsReplacementsAndGaps() {
        for (a, b) in [("", "new\n"), ("old\n", ""), ("first\r\nold\nend", "first\r\nnew\nextra\nend"), ("é\n", "e\u{301}\n"), ("x\n", "x"), ("same\n", "same\n")] {
            let aligned = FileComparisonAlignment(base: a, destination: b)
            XCTAssertEqual(Data(aligned.rows.filter { $0.base.lineNumber != nil }.map(\.base.text).joined().utf8), Data(a.utf8))
            XCTAssertEqual(Data(aligned.rows.filter { $0.destination.lineNumber != nil }.map(\.destination.text).joined().utf8), Data(b.utf8))
            XCTAssertEqual(aligned.differences.flatMap { Array($0) }, aligned.rows.indices.filter { aligned.rows[$0].changed })
            XCTAssertEqual(aligned.differences.isEmpty, a.utf8.elementsEqual(b.utf8))
        }
    }
    func testPinnedRenameAddedDeletedBinaryAndSymlinkContent() async throws {
        let (root, repo, original) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: root.appendingPathComponent(original))
        try Data("removed\n".utf8).write(to: root.appendingPathComponent("deleted.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "old-target")
        try await repo.stage(["deleted.txt", "link"]); _ = try await repo.commit(message: "base contents")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let renamed = ":(glob)* new 雪\n.txt"
        _ = try await repo.run(["mv", "--", original, renamed])
        _ = try await repo.run(["rm", "--", "deleted.txt"])
        try Data([0, 1, 2, 255]).write(to: root.appendingPathComponent("binary.dat"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/outside/repository")
        try await repo.stage(["binary.dat", "link"]); _ = try await repo.commit(message: "new contents")
        let snapshot = try await repo.revisionComparison(from: .revision(base), to: .revision("HEAD"))
        try Data("later\n".utf8).write(to: root.appendingPathComponent(renamed)); try await repo.stage([renamed]); _ = try await repo.commit(message: "advance")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let rename = try await repo.comparisonFile(snapshot, path: renamed)
        XCTAssertEqual(rename.base.path, original); XCTAssertEqual(rename.base.bytes, before); XCTAssertEqual(rename.destination.bytes, before)
        let binary = try await repo.comparisonFile(snapshot, path: "binary.dat")
        XCTAssertTrue(binary.base.bytes.isEmpty); XCTAssertEqual(binary.destination.bytes, Data([0, 1, 2, 255])); XCTAssertNil(binary.destination.text)
        let deleted = try await repo.comparisonFile(snapshot, path: "deleted.txt")
        XCTAssertEqual(deleted.base.text, "removed\n"); XCTAssertTrue(deleted.destination.bytes.isEmpty)
        let link = try await repo.comparisonFile(snapshot, path: "link")
        XCTAssertEqual(link.base.text, "old-target"); XCTAssertEqual(link.destination.text, "/outside/repository"); XCTAssertEqual(link.destination.mode, "120000")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        do { _ = try await repo.comparisonFile(snapshot, path: "../outside"); XCTFail("Reject paths outside snapshot") } catch RevisionComparisonFailure.selection {}
    }
    func testWorkingContentsReverseAndUTF16RemainUnchanged() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        try Data("staged\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        let bytes = Data([0xff, 0xfe]) + "working 雪\r\n".data(using: .utf16LittleEndian)!
        try bytes.write(to: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let snapshot = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree)
        let value = try await repo.comparisonFile(snapshot, path: path)
        XCTAssertEqual(value.base.bytes, original); XCTAssertEqual(value.destination.bytes, bytes); XCTAssertEqual(value.destination.text, "working 雪\r\n")
        let reverse = try await repo.revisionComparison(from: .workingTree, to: .revision("HEAD"))
        let reversed = try await repo.comparisonFile(reverse, path: path)
        XCTAssertEqual(reversed.base.bytes, bytes); XCTAssertEqual(reversed.destination.bytes, original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
    }
}
