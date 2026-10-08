import XCTest
@testable import TurtleGitCore

private final class StreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    func append(_ chunk: GitOutputChunk) { lock.lock(); defer { lock.unlock() }; switch chunk.stream { case .stdout: stdout.append(chunk.data); case .stderr: stderr.append(chunk.data) } }
    var bytes: (Data, Data) { lock.lock(); defer { lock.unlock() }; return (stdout,stderr) }
}
final class GitOutputStreamingTests: XCTestCase {
    func testLiveBinaryChunksBeforeExitAndFinalDrainPreserveBothStreams() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let helper = root.appendingPathComponent("writer"), release = URL(fileURLWithPath:helper.path+".release")
        let script = #"""
        #!/bin/sh
        printf '\000\377\351\233\252\n'
        printf 'live stderr\n' >&2
        while [ ! -f "$0.release" ]; do /bin/sleep 0.01; done
        /usr/bin/head -c 200000 /dev/zero
        /usr/bin/head -c 150000 /dev/zero >&2
        """#
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let capture = StreamCapture(), token = OperationCancellation(), repo = GitRepository(root:root,executable:helper)
        let operation = Task { try await repo.run(["stream-test"],cancellation:token,onOutput:{ capture.append($0) }) }
        let end = Date().addingTimeInterval(5)
        while Date() < end && (capture.bytes.0.count < 6 || capture.bytes.1.isEmpty) { try await Task.sleep(nanoseconds:10_000_000) }
        let live = capture.bytes
        if live.0.count < 6 || live.1.isEmpty { token.cancel(); _ = await operation.result; XCTFail("No live output before release"); return }
        XCTAssertEqual(live.0,Data([0,255,233,155,170,10])); XCTAssertEqual(live.1,Data("live stderr\n".utf8))
        try Data().write(to:release); let result = try await operation.value, final = capture.bytes
        XCTAssertEqual(result.stdout,final.0); XCTAssertEqual(result.stderr,final.1)
        XCTAssertEqual(result.stdout.count,200006); XCTAssertEqual(result.stderr.count,150012)
    }
}
