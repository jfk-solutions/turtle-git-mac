import XCTest
@testable import TurtleGitCore

final class WorkingPatchBatchTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository, WorkingTreePatchReview) {
        let (root, repository, _) = try await GitPatchTests().fixture()
        for path in ["a 雪.txt", "middle.txt", "z.txt"] { try Data("before\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repository.stage(["a 雪.txt", "middle.txt", "z.txt"]); _ = try await repository.commit(message: "patch files")
        for path in ["a 雪.txt", "middle.txt", "z.txt"] { try Data("after\n".utf8).write(to: root.appendingPathComponent(path)) }
        let bytes = try await repository.run(["diff", "--binary", "--"]).stdout
        for path in ["a 雪.txt", "z.txt"] { try Data("before\n".utf8).write(to: root.appendingPathComponent(path)) }
        try Data("conflicting\n".utf8).write(to: root.appendingPathComponent("middle.txt"))
        return (root, repository, try await repository.reviewWorkingTreePatch(bytes))
    }
    func testOrderedBatchContinuesAfterConflictWithoutChangingIndexOrHead() async throws {
        let (root, repository, review) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(review.canApply)
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let result = try await repository.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id)))
        XCTAssertFalse(result.cancelled); XCTAssertEqual(result.files.map { String(decoding: $0.pathBytes, as: UTF8.self) }, ["a 雪.txt", "middle.txt", "z.txt"])
        XCTAssertEqual(result.files.map(\.success), [true,false,true]); XCTAssertTrue(result.files[1].output.contains("middle.txt"))
        for path in ["a 雪.txt", "z.txt"] { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path)), "after\n") }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("middle.txt")), "conflicting\n")
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(head, afterHead); XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index")))
    }
    func testCancellationRetainsCompletedFileAndStopsBeforeTheNext() async throws {
        let (root, repository, review) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = OperationCancellation()
        let result = try await repository.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id)), cancellation: token) { _ in token.cancel() }
        XCTAssertTrue(result.cancelled); XCTAssertEqual(result.files.count, 1); XCTAssertTrue(result.files[0].success)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("z.txt")), "before\n")
    }
    func testInvalidSelectionAndForeignReviewAreRefusedBeforeMutation() async throws {
        let (root, repository, review) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repository.applyWorkingTreePatchBatch(review, fileIDs: [999]); XCTFail("Invalid selection accepted") } catch WorkingTreePatchFailure.review {}
        let foreign = GitRepository(root: root.appendingPathComponent("foreign"))
        do { _ = try await foreign.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id))); XCTFail("Foreign review accepted") } catch WorkingTreePatchFailure.review {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a 雪.txt")), "before\n")
    }
}
