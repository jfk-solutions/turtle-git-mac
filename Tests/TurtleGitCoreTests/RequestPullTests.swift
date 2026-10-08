import XCTest
@testable import TurtleGitCore

final class RequestPullTests: XCTestCase {
    func testRequestTextUsesPublishedRangeAndPreservesMixedChanges() async throws {
        let (root, repo, remote, path) = try await PushTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("committed update\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "Request change 雪")
        var push = PushOptions(); push.remote = "origin"; push.source = "main"; _ = try await repo.push(push)
        try Data("staged\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); try Data("working\n".utf8).write(to: root.appendingPathComponent(path))
        let index = try await repo.run(["diff", "--cached", "--binary"]).stdout, working = try await repo.run(["diff", "--binary"]).stdout
        let refs = try await remote.run(["show-ref"]).stdout
        var options = RequestPullOptions(); options.start = base; options.repositoryURL = remote.root.path; options.end = "main"
        let bytes = try await repo.requestPull(options)
        let expected = try await repo.run(["request-pull", "--", base, remote.root.path, "main"]).stdout
        XCTAssertEqual(bytes, expected); XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Request change 雪"))
        let nextIndex = try await repo.run(["diff", "--cached", "--binary"]).stdout, nextWorking = try await repo.run(["diff", "--binary"]).stdout, nextRefs = try await remote.run(["show-ref"]).stdout
        XCTAssertEqual(index, nextIndex); XCTAssertEqual(working, nextWorking); XCTAssertEqual(refs, nextRefs)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/base", base])
        options.start = "remotes/origin/base"
        let normalized = try await repo.requestPull(options); XCTAssertEqual(bytes, normalized)
    }
    func testInvalidEndNamesAndUnpublishedRevisionProduceNoRequest() async throws {
        let (root, repo, remote, _) = try await PushTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["", "HEAD", "-option", "main:remote", "bad name", "name|bad", "name<bad", "name>bad", "name\"bad", "bad\0name"] {
            do { try await repo.validateRequestPullEnd(name); XCTFail("Invalid end: \(name)") } catch RequestPullFailure.end {}
        }
        var options = RequestPullOptions(); options.start = "main"; options.repositoryURL = remote.root.path; options.end = "main"
        do { _ = try await repo.requestPull(options); XCTFail("The remote has not published main") } catch is GitFailure {}
        options.start = "bad\0start"
        do { _ = try await repo.requestPull(options); XCTFail("NUL") } catch RequestPullFailure.argument {}
        options.start = "main"
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.requestPull(options, cancellation: token); XCTFail("Pre-cancelled") } catch is OperationCancellationFailure {}
        let refs = try await remote.checkoutReferences(); XCTAssertTrue(refs.isEmpty)
    }
    func testTagAndBareRepositoryRequest() async throws {
        let (root, repo, remote, _) = try await PushTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["commit", "--allow-empty", "-m", "next"]); _ = try await repo.run(["tag", "release"])
        var push = PushOptions(); push.remote = "origin"; push.source = "main"; push.includeTags = true; _ = try await repo.push(push)
        var options = RequestPullOptions(); options.start = base; options.repositoryURL = remote.root.path; options.end = "release"
        let request = try await remote.requestPull(options)
        XCTAssertTrue(String(decoding: request, as: UTF8.self).contains("next"))
    }
}
