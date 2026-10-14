import XCTest
@testable import TurtleGitCore

final class ResolveProgressTests: XCTestCase {
    final class Events: @unchecked Sendable {
        let lock = NSLock(); var values: [ConflictResolutionProgress] = []; var bytes = Data()
        func record(_ event: ConflictResolutionProgress) { lock.lock(); values.append(event); lock.unlock() }
        func append(_ chunk: GitOutputChunk) { lock.lock(); bytes.append(chunk.data); lock.unlock() }
    }
    func testPreCancelledResolvePreservesIndexAndWorkingContents() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try await repo.conflicts(), index = try Data(contentsOf: root.appendingPathComponent(".git/index")), contents = try Data(contentsOf: root.appendingPathComponent(path))
        let token = OperationCancellation(); token.cancel(); let events = Events()
        do { _ = try await repo.resolveConflicts(entries, using: .theirs, cancellation: token, onOutput: events.append, onProgress: events.record); XCTFail("Cancelled mutation accepted") }
        catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), contents)
        XCTAssertTrue(events.values.isEmpty); XCTAssertTrue(events.bytes.isEmpty)
    }
    func testCancellationAfterFirstResolvedPathKeepsSecondConflictAndUnrelatedIndex() async throws {
        let (root, repo, first) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await repo.conflicts(); let second = "zz-second 雪.txt"
        let records = original[0].stages.map { "\($0.mode) \($0.object) \($0.number)\t\(second)\0" }.joined()
        _ = try await repo.run(["update-index", "-z", "--index-info"], input: Data(records.utf8))
        try Data("second working\n".utf8).write(to: root.appendingPathComponent(second))
        let entries = try await repo.conflicts(); XCTAssertEqual(entries.count, 2)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let token = OperationCancellation(), events = Events()
        do {
            _ = try await repo.resolveConflicts(entries, using: .mine, cancellation: token, onOutput: events.append, onProgress: { event in
                events.record(event); if event.finished && event.completed == 1 { token.cancel() }
            }); XCTFail("Cancellation ignored between paths")
        } catch OperationCancellationFailure.cancelled {}
        let remaining = try await repo.conflicts(), after = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(remaining.map(\.path), [second]); XCTAssertEqual(remaining.first?.stages, original.first?.stages)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(first)), "mine\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(second)), "second working\n")
        let unrelated = try await repo.run(["show", ":other.txt"]).text
        XCTAssertEqual(unrelated, "other index\n"); XCTAssertEqual(head, after)
        XCTAssertEqual(events.values.map(\.completed), [0, 1]); XCTAssertEqual(events.values.map(\.finished), [false, true])
        XCTAssertTrue(String(decoding: events.bytes, as: UTF8.self).contains("Resolved: " + first))
    }
    func testSilentGitStillReportsResolvedNotificationAndExactReturnOutput() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = Events(), entries = try await repo.conflicts()
        let text = try await repo.resolveConflicts(entries, using: .theirs, onOutput: events.append, onProgress: events.record)
        XCTAssertEqual(text, "Resolved: " + path)
        XCTAssertEqual(String(decoding: events.bytes, as: UTF8.self), text + "\n")
        XCTAssertEqual(events.values.map(\.completed), [0, 1]); XCTAssertTrue(events.values.last!.finished)
        XCTAssertEqual(events.values.last!.total, 1)
    }
}
