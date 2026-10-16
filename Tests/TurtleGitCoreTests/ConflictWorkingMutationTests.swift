import XCTest
@testable import TurtleGitCore

final class ConflictWorkingMutationTests:XCTestCase {
    func fixture() async throws -> (URL,GitRepository,[ConflictEntry]) {
        let (root,repo,path) = try await ConflictResolutionTests().fixture()
        let captured = try await repo.conflicts(),second = "second \t conflict.txt"
        let records = captured[0].stages.map{"\($0.mode) \($0.object) \($0.number)\t\(second)\u{0}"}.joined()
        _ = try await repo.run(["update-index","-z","--index-info"],input:Data(records.utf8))
        try Data("second private contents\n".utf8).write(to:root.appendingPathComponent(second))
        return (root,repo,try await repo.conflicts(paths:[path,second]))
    }
    func testRealConflictSelectionPreservesRequestedOrderAndRawIndex() async throws {
        let (root,repo,entries) = try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let before = try Data(contentsOf:root.appendingPathComponent(".git/index")),ordered = Array(entries.reversed())
        let rows = try await repo.conflictWorkingFileSelection(ordered),actual = try await repo.status(refreshIndex:false)
        XCTAssertEqual(rows.map(\.path),ordered.map(\.path));XCTAssertTrue(rows.allSatisfy{actual.contains($0) && $0.state == .conflicted})
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),before)
        _ = try await repo.resolveConflicts([entries[0]],using:.theirs)
        let changed = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        do {_ = try await repo.conflictWorkingFileSelection(ordered);XCTFail("Stale stages accepted")}catch ResolveFailure.stale {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),changed)
    }
    func testMissingConflictDeleteUsesCapturedMarkAndOnlySelectedIndexEntries() async throws {
        for permanent in [false,true] {
            let (root,repo,entries) = try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            let head = try await repo.run(["rev-parse","HEAD"]).stdout,other = try await repo.run(["show",":other.txt"]).stdout
            let marker = entries[0].path,existing = entries[1].path,contents = try Data(contentsOf:root.appendingPathComponent(existing))
            let before = try Data(contentsOf:root.appendingPathComponent(".git/index"))
            do {_ = try await repo.deleteConflictWorkingFiles(entries,markedPath:marker,permanently:permanent);XCTFail("Existing conflict mark enabled Delete")}catch {}
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),before)
            try FileManager.default.removeItem(at:root.appendingPathComponent(marker))
            let cancelled = OperationCancellation();cancelled.cancel()
            do {_ = try await repo.deleteConflictWorkingFiles(entries,markedPath:marker,permanently:permanent,cancellation:cancelled);XCTFail("Cancelled delete ran")}catch {}
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),before)
            let result = try await repo.deleteConflictWorkingFiles(entries,markedPath:marker,permanently:permanent)
            defer{for url in result.trashedFiles {try? FileManager.default.removeItem(at:url)}}
            XCTAssertEqual(Set(result.removedIndexPaths),Set(entries.map(\.path)));XCTAssertEqual(result.removedPaths,[existing])
            XCTAssertEqual(result.trashedFiles.count,permanent ? 0:1)
            if let trash = result.trashedFiles.first {XCTAssertEqual(try Data(contentsOf:trash),contents)}
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(existing).path))
            let remaining = try await repo.conflicts(),afterHead = try await repo.run(["rev-parse","HEAD"]).stdout,afterOther = try await repo.run(["show",":other.txt"]).stdout
            XCTAssertTrue(remaining.isEmpty);XCTAssertEqual(afterHead,head);XCTAssertEqual(afterOther,other)
        }
    }
}
