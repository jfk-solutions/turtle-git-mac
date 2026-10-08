import XCTest
@testable import TurtleGitCore

final class FetchPullOutputTests: XCTestCase {
    func testFetchRebaseAndPullObserversMatchRawResultsAndRepositoryEffects() async throws {
        let (root, publisher, _, consumer, _) = try await PullTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await PullTests().publish(root, publisher)
        var fetch = FetchOptions(); fetch.remote = "origin"; fetch.branch = "main"
        let capturedFetch = FetchPullStreamCapture()
        let text = try await consumer.fetch(fetch, onOutput: { capturedFetch.append($0) })
        XCTAssertEqual(text, capturedFetch.text)
        let capturedRebase = FetchPullStreamCapture()
        let result = try await consumer.fetchForRebase(fetch, onOutput: { capturedRebase.append($0) })
        XCTAssertEqual(result.output, capturedRebase.text)
        XCTAssertTrue(result.canFastForward)
        let capturedPull = FetchPullStreamCapture()
        let pull = try await consumer.pull(PullTests().options(), onOutput: { capturedPull.append($0) })
        XCTAssertEqual(pull, capturedPull.text)
        let head = try await consumer.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(head, result.upstream)
        XCTAssertTrue(FileManager.default.fileExists(atPath: consumer.root.appendingPathComponent("remote.txt").path))
    }
    func testRebasePreparationFailurePreservesSuccessfulTransportDiagnostics() async throws {
        let (root, _, _, consumer, _) = try await FetchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fetchHead = consumer.root.appendingPathComponent(".git/FETCH_HEAD")
        if FileManager.default.fileExists(atPath: fetchHead.path) { try FileManager.default.removeItem(at: fetchHead) }
        let helper = root.appendingPathComponent("metadata-failure-git")
        let script = #"""
        #!/bin/sh
        if [ "${4-}" = fetch ]; then
          printf 'successful transport diagnostic\n' >&2
          exit 0
        fi
        exec /usr/bin/git "$@"
        """#
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let repo = GitRepository(root: consumer.root, executable: helper), capture = FetchPullStreamCapture()
        var options = FetchOptions(); options.remote = "origin"; options.branch = "main"
        do { _ = try await repo.fetchForRebase(options, onOutput: { capture.append($0) }); XCTFail("Missing fetched target accepted") }
        catch let failure as FetchRebaseExecutionFailure {
            XCTAssertEqual(failure.output, "successful transport diagnostic\n")
            XCTAssertEqual(failure.output, capture.text)
            XCTAssertEqual(failure.commandFailure?.arguments.first, "rev-parse")
            XCTAssertTrue(failure.commandFailure?.arguments.contains("FETCH_HEAD^{commit}") == true)
            XCTAssertTrue(failure.localizedDescription.contains("successful transport diagnostic"))
            XCTAssertTrue(failure.localizedDescription.contains("Preparing Rebase failed"))
        }
    }
}
private final class FetchPullStreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    func append(_ chunk: GitOutputChunk) { lock.lock(); defer { lock.unlock() }; switch chunk.stream { case .stdout: stdout.append(chunk.data); case .stderr: stderr.append(chunk.data) } }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: stdout + stderr, as: UTF8.self) }
}
