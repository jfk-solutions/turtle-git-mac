import XCTest
@testable import TurtleGitCore

private final class RevertEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WorkingFileRevertProgress] = []
    func append(_ event: WorkingFileRevertProgress) { lock.lock(); events.append(event); lock.unlock() }
    var snapshot: [WorkingFileRevertProgress] { lock.lock(); defer { lock.unlock() }; return events }
}

final class WorkingFileRevertProgressTests: XCTestCase {
    func testAlreadyCancelledDoesNotTouchRepository() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local work".utf8)
        try bytes.write(to: root.appendingPathComponent(path))
        let selected = try await repo.status()
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let token = OperationCancellation(), recorder = RevertEventRecorder()
        token.cancel()
        do {
            _ = try await repo.revertWorkingFiles(selected, cancellation: token) { recorder.append($0) }
            XCTFail("Cancelled operation succeeded")
        } catch { XCTAssertTrue(error is OperationCancellationFailure) }
        XCTAssertTrue(recorder.snapshot.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }

    func testCancellationAfterTrashPreservesIndexAndReturnsExactRecoveryURL() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let second = "z 雪\nsecond.txt"
        try Data("second base".utf8).write(to: root.appendingPathComponent(second))
        try await repo.stage([second]); _ = try await repo.commit(message: "second")
        let firstBytes = Data([0, 255, 10]), secondBytes = Data("second local".utf8)
        try firstBytes.write(to: root.appendingPathComponent(path))
        try secondBytes.write(to: root.appendingPathComponent(second))
        let selected = try await repo.status(), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let token = OperationCancellation(), recorder = RevertEventRecorder()
        var copies: [URL] = []
        defer { for copy in copies { try? FileManager.default.removeItem(at: copy) } }
        do {
            _ = try await repo.revertWorkingFiles(selected, cancellation: token) { event in
                recorder.append(event)
                if event.step == .recycle && event.finished { token.cancel() }
            }
            XCTFail("Cancellation succeeded")
        } catch let failure as WorkingFileRevertFailure {
            XCTAssertTrue(failure.wasCancelled); copies = failure.trashedFiles
        }
        let moved = try XCTUnwrap(recorder.snapshot.first { $0.finished })
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), moved.path == path ? firstBytes : secondBytes)
        let remaining = moved.path == path ? second : path
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(remaining)), remaining == path ? firstBytes : secondBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(moved.path).path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(afterHead, head)
        XCTAssertEqual(recorder.snapshot.filter(\.finished).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }

    func testCancellationAtRestoreStartDoesNotRunCheckout() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        let selected = try await repo.status(), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let token = OperationCancellation(), recorder = RevertEventRecorder()
        do {
            _ = try await repo.revertWorkingFiles(selected, cancellation: token) { event in
                recorder.append(event)
                if event.step == .restore && !event.finished { token.cancel() }
            }
            XCTFail("Cancellation succeeded")
        } catch let failure as WorkingFileRevertFailure {
            XCTAssertTrue(failure.wasCancelled); XCTAssertTrue(failure.trashedFiles.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertTrue(recorder.snapshot.filter(\.finished).isEmpty)
    }

    func testCancellationBetweenBatchesStopsLaterWorkingFileChanges() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (0..<70).map { String(format: "batch-%03d.txt", $0) }
        for path in paths { try Data(path.utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(paths); _ = try await repo.commit(message: "batch")
        for path in paths { try FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
        let selected = try await repo.status(), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let token = OperationCancellation(), recorder = RevertEventRecorder()
        do {
            _ = try await repo.revertWorkingFiles(selected, cancellation: token) { event in
                recorder.append(event)
                if event.completed == 64 { token.cancel() }
            }
            XCTFail("Cancellation succeeded")
        } catch let failure as WorkingFileRevertFailure {
            XCTAssertTrue(failure.wasCancelled); XCTAssertTrue(failure.trashedFiles.isEmpty)
        }
        for path in paths.prefix(64) { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data(path.utf8)) }
        for path in paths.suffix(6) { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(recorder.snapshot.filter(\.finished).count, 64)
        XCTAssertEqual(recorder.snapshot.last?.total, 70)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }

    func testSuccessReportsAllOperationsAndLeavesAddedWorkingFile() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try Data(contentsOf: root.appendingPathComponent(path))
        try Data("edited".utf8).write(to: root.appendingPathComponent(path))
        let added = ":(glob)* 雪\nnew.txt", addedBytes = Data("added".utf8)
        try addedBytes.write(to: root.appendingPathComponent(added)); try await repo.stage([added])
        let selected = try await repo.status(), recorder = RevertEventRecorder()
        let result = try await repo.revertWorkingFiles(selected) { recorder.append($0) }
        defer { for copy in result.trashedFiles { try? FileManager.default.removeItem(at: copy) } }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), base)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(added)), addedBytes)
        let tracked = try await repo.trackedPaths(); XCTAssertFalse(tracked.contains(added))
        let finished = recorder.snapshot.filter(\.finished)
        XCTAssertEqual(finished.count, 3)
        XCTAssertEqual(finished.map(\.completed), [1, 2, 3])
        XCTAssertTrue(recorder.snapshot.allSatisfy { $0.total == 3 })
        XCTAssertEqual(Set(finished.map(\.step)), [.unstage, .recycle, .restore])
        XCTAssertEqual(result.trashedFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.trashedFiles.first)), Data("edited".utf8))
    }
}
