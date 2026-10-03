import XCTest
@testable import TurtleGitCore

final class FinderRequestTests: XCTestCase {
    func testCompleteSelectionRoundTripsLiteralPathsAndLegacyRequest() throws {
        let paths = ["/repo/a b 雪\n?#%.txt", "/repo/second.txt"]
        let request = FinderRequest(action: .diff, paths: paths.map { URL(fileURLWithPath: $0) })
        let decoded = try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url)))
        XCTAssertEqual(decoded.action, .diff)
        XCTAssertEqual(decoded.paths.map(\.path), paths)
        XCTAssertEqual(FinderRequest(url: URL(string: "turtlegit://action?command=log&path=%2Frepo%2Ffile")!)?.paths.first?.path, "/repo/file")
        XCTAssertEqual(FinderRequest(action: .diff, paths: request.paths + request.paths).paths.count, 2)
    }
    func testMalformedRequestsAreRejected() {
        for value in ["https://action?command=diff&path=/repo", "turtlegit://action?command=diff&command=log&path=/repo", "turtlegit://action?command=diff&path=relative", "turtlegit://action?command=diff&path=/repo%00file", "turtlegit://action?command=diff&path", "turtlegit://action?command=unknown&path=/repo"] {
            XCTAssertNil(FinderRequest(url: URL(string: value)!), value)
        }
    }
    func testDirectoriesExpandWithoutSelectingSimilarlyNamedSiblings() {
        let root = URL(fileURLWithPath: "/repo")
        let entries = StatusEntry.parse(Data(" M dir/a\0?? dir/b\0 M directory/c\0 M other\0".utf8))
        let request = FinderRequest(action: .status, paths: [root.appendingPathComponent("dir"), root.appendingPathComponent("other")])
        XCTAssertEqual(request.selectedStatusPaths(root: root, entries: entries), ["dir/a", "dir/b", "other"])
        XCTAssertEqual(request.relativePaths(root: root), ["dir", "other"])
        XCTAssertEqual(FinderRequest(action: .status, paths: [root]).selectedStatusPaths(root: root, entries: entries), Set(entries.map(\.path)))
    }
    func testMultiPathHistoryAndDiffStayScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = GitRepository(root: root)
        _ = try await repository.run(["init", "-b", "main"])
        _ = try await repository.run(["config", "user.name", "Finder Tests"])
        _ = try await repository.run(["config", "user.email", "finder@example.invalid"])
        _ = try await repository.run(["config", "commit.gpgsign", "false"])
        for path in ["*.txt", "雪\n.txt", "other.txt"] {
            try Data("initial\n".utf8).write(to: root.appendingPathComponent(path))
            try await repository.stage([path]); _ = try await repository.commit(message: path)
        }
        var options = HistoryOptions(); options.paths = ["*.txt", "雪\n.txt"]
        let history = try await repository.history(options: options)
        XCTAssertEqual(Set(history.map(\.subject)), ["*.txt", "雪 .txt"])
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("other.txt"))
        let cleanSelectionDiff = try await repository.diff(path: "*.txt")
        XCTAssertTrue(cleanSelectionDiff.isEmpty)
    }
}
