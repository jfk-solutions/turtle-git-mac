import XCTest
@testable import TurtleGitCore

final class ReferenceLogTests: XCTestCase {
    func testReflogRowsPreserveDistinctSelectorsDateAndUnicodeSubjects() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for message in ["first 雪", "second: details"] {
            try Data(message.utf8).write(to: root.appendingPathComponent(path))
            var options = StashSaveOptions(); options.message = message; _ = try await repo.saveStash(options)
        }
        let rows = try await repo.referenceLog("refs/stash")
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(rows.map(\.selector), ["refs/stash@{0}", "refs/stash@{1}"])
        XCTAssertEqual(rows[0].action, "On main"); XCTAssertEqual(rows[0].message, "second: details")
        XCTAssertEqual(rows[1].message, "first 雪"); XCTAssertNotNil(rows[0].date)
        let names = try await repo.referenceLogNames(); XCTAssertTrue(names.contains("HEAD")); XCTAssertTrue(names.contains("refs/stash"))
        let head = try await repo.referenceLog("HEAD"); XCTAssertTrue(head.contains { $0.subject == "commit (initial): base" })
    }
    func testMultiDropUsesOriginalIndicesAndPreservesHeadIndexWorktree() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for n in 0..<4 { try Data("stash \(n)".utf8).write(to: root.appendingPathComponent(path)); _ = try await repo.saveStash(StashSaveOptions()) }
        let expected = try await repo.referenceLog("refs/stash")
        try Data("local\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); try Data("later\n".utf8).write(to: root.appendingPathComponent(path))
        let head = try await repo.run(["rev-parse", "HEAD"]).text, index = try await repo.diff(staged: true), work = try await repo.diff()
        _ = try await repo.deleteStashEntries([expected[0].selector, expected[2].selector], expected: expected)
        let remaining = try await repo.referenceLog("refs/stash")
        XCTAssertEqual(remaining.map(\.hash), [expected[1].hash, expected[3].hash])
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text, afterIndex = try await repo.diff(staged: true), afterWork = try await repo.diff()
        XCTAssertEqual(head, afterHead); XCTAssertEqual(index, afterIndex); XCTAssertEqual(work, afterWork)
    }
    func testStaleSnapshotRejectsDropAndClearEvenIfSelectionStillHasSameIndex() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("older\n".utf8).write(to: root.appendingPathComponent(path)); _ = try await repo.saveStash(StashSaveOptions())
        let old = try await repo.referenceLog("refs/stash")
        try Data("newer\n".utf8).write(to: root.appendingPathComponent(path)); _ = try await repo.saveStash(StashSaveOptions())
        let current = try await repo.referenceLog("refs/stash")
        for clear in [false, true] {
            do { _ = try await repo.deleteStashEntries([old[0].selector], expected: old, clear: clear); XCTFail("Stale snapshot accepted") } catch ReferenceLogFailure.stale {}
            let after = try await repo.referenceLog("refs/stash"); XCTAssertEqual(current, after)
        }
        _ = try await repo.deleteStashEntries([], expected: current, clear: true)
        let empty = try await repo.referenceLog("refs/stash"); XCTAssertTrue(empty.isEmpty)
    }
    func testEmptyReflogAndInvalidReferenceSelection() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let empty = try await repo.referenceLog("refs/stash"); XCTAssertTrue(empty.isEmpty)
        for ref in ["--all", "refs/stash\0", "refs/stash\nHEAD"] {
            do { _ = try await repo.referenceLog(ref); XCTFail("Invalid reference accepted") } catch ReferenceLogFailure.reference {}
        }
        do { _ = try await repo.deleteStashEntries(["refs/stash@{0}"], expected: []); XCTFail("Empty selection accepted") } catch ReferenceLogFailure.selection {}
    }
}
