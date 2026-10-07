import XCTest
@testable import TurtleGitCore

final class CleanProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CleanProgress] = []
    func append(_ event: CleanProgress) { lock.lock(); defer { lock.unlock() }; values.append(event) }
    var events: [CleanProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

final class CleanProgressTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository, CleanPreview) {
        let (root, source, _) = try await GitPatchTests().fixture()
        let executable = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? source.executable
        let repo = GitRepository(root: root, executable: executable)
        do {
            for name in ["a 雪\n", "b"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
            return (root, repo, try await repo.cleanPreview())
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func testSuccessfulEventsBracketRealFilesystemRemovals() async throws {
        let (root, repo, plan) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = CleanProgressRecorder()
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let result = try await repo.executeClean(plan, permanently: true) { event in
            recorder.append(event)
            XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent(event.path).path), !event.finished)
        }
        let events = recorder.events
        XCTAssertEqual(events.map(\.path), plan.candidates.flatMap { [$0, $0] })
        XCTAssertEqual(events.map(\.finished), [false, true, false, true])
        XCTAssertEqual(events.map(\.completed), [0, 1, 1, 2])
        XCTAssertTrue(events.allSatisfy { $0.repository == repo.root && $0.total == 2 })
        XCTAssertEqual(result.removedPaths, plan.candidates)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testFailureDoesNotEmitFinishedForUnremovedItem() async throws {
        let (root, repo, plan) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = CleanProgressRecorder(), last = root.appendingPathComponent(plan.candidates.last!)
        do {
            _ = try await repo.executeClean(plan, permanently: true, cancellation: nil, progress: { recorder.append($0) }, removal: { location, _ in
                if location == last { throw NSError(domain: "OwnedCleanProgressFailure", code: 1) }
                try FileManager.default.removeItem(at: location); return nil
            }); XCTFail("Removal failure ignored")
        } catch let failure as CleanExecutionFailure {
            XCTAssertEqual(failure.failedPath, plan.candidates.last)
            XCTAssertEqual(failure.result.removedPaths, [plan.candidates[0]])
        }
        XCTAssertEqual(recorder.events.map(\.finished), [false, true, false])
        XCTAssertEqual(recorder.events.map(\.completed), [0, 1, 1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: last.path))
    }
    func testStartedCallbackCancellationPreventsCurrentRemoval() async throws {
        let (root, repo, plan) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = CleanProgressRecorder(), cancellation = OperationCancellation()
        do {
            _ = try await repo.executeClean(plan, permanently: true, cancellation: cancellation) { event in recorder.append(event); cancellation.cancel() }
            XCTFail("Started cancellation ignored")
        } catch let failure as CleanExecutionFailure {
            XCTAssertTrue(failure.cancelled); XCTAssertTrue(failure.result.removedPaths.isEmpty)
        }
        XCTAssertEqual(recorder.events.map(\.completed), [0]); XCTAssertEqual(recorder.events.map(\.finished), [false])
        XCTAssertTrue(plan.candidates.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }
    func testStalePlanAndLockRefusalEmitNoRemovalEvents() async throws {
        let (root, repo, plan) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = CleanProgressRecorder()
        let lock = root.appendingPathComponent(".git/index.lock")
        try Data("foreign".utf8).write(to: lock)
        do { _ = try await repo.executeClean(plan, permanently: true) { recorder.append($0) }; XCTFail("Lock ignored") } catch CleanFailure.locked {}
        XCTAssertTrue(recorder.events.isEmpty)
        try FileManager.default.removeItem(at: lock)
        try Data("new".utf8).write(to: root.appendingPathComponent("new"))
        do { _ = try await repo.executeClean(plan, permanently: true) { recorder.append($0) }; XCTFail("Stale plan ignored") } catch CleanFailure.changed {}
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertTrue(plan.candidates.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) })
    }
}
