import XCTest
@testable import TurtleGitCore

final class MergeOutputTests: XCTestCase {
    func testMergeObserverMatchesCompleteResultAndFastForwardEffect() async throws {
        let (root, repo, _) = try await MergeTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var options = MergeOptions(); options.revision = "refs/heads/feature"; options.fastForwardOnly = true
        let expected = try await repo.run(["rev-parse", options.revision]).text
        let capture = MergeStreamCapture()
        let text = try await repo.merge(options, onOutput: { capture.append($0) })
        XCTAssertEqual(text, capture.text)
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        XCTAssertEqual(head, expected)
    }
    func testConflictObserverMatchesFailureAndKeepsUnmergedStages() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["switch", "-c", "feature"])
        try Data("theirs\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"])
        try Data("ours\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "ours")
        let capture = MergeStreamCapture(); var options = MergeOptions(); options.revision = "feature"
        do { _ = try await repo.merge(options, onOutput: { capture.append($0) }); XCTFail("Conflicting merge accepted") }
        catch let failure as GitFailure { XCTAssertEqual(failure.message, capture.text); XCTAssertTrue(failure.message.contains("CONFLICT")) }
        let unmerged = try await repo.run(["ls-files", "--unmerged", "--", path]).stdout.split(separator: 10)
        XCTAssertEqual(unmerged.count, 3)
    }
}
private final class MergeStreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    func append(_ chunk: GitOutputChunk) { lock.lock(); defer { lock.unlock() }; switch chunk.stream { case .stdout: stdout.append(chunk.data); case .stderr: stderr.append(chunk.data) } }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: stdout + stderr, as: UTF8.self) }
}
