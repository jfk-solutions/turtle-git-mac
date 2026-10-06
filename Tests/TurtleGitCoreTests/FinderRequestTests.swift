import XCTest
@testable import TurtleGitCore

final class FinderRequestTests: XCTestCase {
    func testBisectRequestsUseNativeWorkflowAndRequireWorktree() throws {
        let folder = URL(fileURLWithPath: "/repo 雪/subdir", isDirectory: true)
        for action in [RepositoryAction.bisectStart, .bisectGood, .bisectBad, .bisectSkip, .bisectReset] {
            let request = FinderRequest(action: action, paths: [folder])
            let decoded = try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url)))
            XCTAssertEqual(decoded.action, action); XCTAssertEqual(decoded.paths.map(\.path), [folder.path])
            XCTAssertTrue(action.requiresWorkingTree); XCTAssertNil(action.arguments(value: ""))
            XCTAssertNotNil(action.icon.image())
        }
        XCTAssertEqual(RepositoryAction.bisectGood.bisectOperation, .good)
        XCTAssertEqual(RepositoryAction.bisectBad.bisectOperation, .bad)
        XCTAssertEqual(RepositoryAction.bisectSkip.bisectOperation, .skip)
        XCTAssertEqual(RepositoryAction.bisectReset.bisectOperation, .reset)
        XCTAssertNil(RepositoryAction.bisectStart.bisectOperation)
    }
    func testExportRoundTripUsesDialogAndAllowsBareRepository() throws {
        let folder = URL(fileURLWithPath: "/repo 雪/subfolder", isDirectory: true)
        let request = FinderRequest(action: .export, paths: [folder])
        let decoded = try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url)))
        XCTAssertEqual(decoded.action, .export); XCTAssertEqual(decoded.paths.map(\.path), [folder.path])
        XCTAssertEqual(decoded.action.icon, .export); XCTAssertNil(decoded.action.arguments(value: ""))
        XCTAssertFalse(decoded.action.requiresWorkingTree)
        XCTAssertTrue(FinderRepositoryMetadata(bare: true).allows(.export))
        XCTAssertTrue(FinderShellRules.allows(.export, flags: [.folderInGit, .onlyOne]))
        XCTAssertTrue(FinderShellRules.allows(.export, flags: [.bare]))
        XCTAssertFalse(FinderShellRules.allows(.export, flags: [.inGit, .onlyOne]))
        XCTAssertFalse(FinderShellRules.allows(.export, flags: [.folderInGit, .two]))
    }
    func testCompleteSelectionRoundTripsLiteralPathsAndLegacyRequest() throws {
        let paths = ["/repo/a b 雪\n?#%.txt", "/repo/second.txt"]
        let request = FinderRequest(action: .diff, paths: paths.map { URL(fileURLWithPath: $0) })
        let decoded = try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url)))
        XCTAssertEqual(decoded.action, .diff)
        XCTAssertEqual(decoded.paths.map(\.path), paths)
        XCTAssertEqual(FinderRequest(url: URL(string: "turtlegit://action?command=log&path=%2Frepo%2Ffile")!)?.paths.first?.path, "/repo/file")
        XCTAssertEqual(FinderRequest(action: .diff, paths: request.paths + request.paths).paths.count, 2)
    }
    func testWorkingMarkAndClearRequestsRoundTripWithoutGitArguments() throws {
        for action in [RepositoryAction.diffLater, .clearComparisonMark] {
            let file = URL(fileURLWithPath: "/outside repository/雪\n?#%.txt")
            let request = FinderRequest(action: action, paths: [file])
            let decoded = try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url)))
            XCTAssertEqual(decoded.action, action); XCTAssertEqual(decoded.paths, [file])
            XCTAssertNil(action.arguments(value: "")); XCTAssertFalse(action.requiresWorkingTree)
            XCTAssertEqual(action.icon, .compare)
        }
    }
    func testRepositoryBrowserRequestPreservesSelectionAndSupportsBareRepositories() throws {
        let paths = [URL(fileURLWithPath: "/repository 雪.git"), URL(fileURLWithPath: "/repository 雪.git/nested")]
        let request = FinderRequest(action: .repositoryBrowser, paths: paths)
        let decoded = try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url)))
        XCTAssertEqual(decoded.action, .repositoryBrowser); XCTAssertEqual(decoded.paths, paths)
        XCTAssertFalse(decoded.action.requiresWorkingTree); XCTAssertNil(decoded.action.arguments(value: ""))
        XCTAssertEqual(decoded.action.icon, .repositoryBrowser)
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
    func testDiscoveredRootUsesTheSameMacOSAliasSpellingAsFinderSelection() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        let discovered = try await repo.discoverRoot()
        let path = root.appendingPathComponent("file 雪\n.txt")
        let request = FinderRequest(action: .rename, paths: [path])
        XCTAssertEqual(discovered.path, root.standardizedFileURL.path)
        XCTAssertEqual(request.relativePaths(root: discovered), ["file 雪\n.txt"])
        XCTAssertEqual(request.selectedStatusPaths(root: discovered, entries: [StatusEntry(path: "file 雪\n.txt", originalPath: nil, index: " ", worktree: "M")]), ["file 雪\n.txt"])
        XCTAssertTrue(RepositoryAccessLease(url: root).contains(request.paths[0]))
        XCTAssertEqual(FinderRequest(action: .status, paths: [root.appendingPathComponent("deleted/sub/file")]).relativePaths(root: discovered), ["deleted/sub/file"])
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
        try Data("selected change\n".utf8).write(to: root.appendingPathComponent("*.txt"))
        let scopedDiff = try await repository.diff(paths: ["*.txt", "雪\n.txt", "*.txt"])
        XCTAssertTrue(scopedDiff.contains("+selected change"))
        XCTAssertFalse(scopedDiff.contains("other.txt"))
        XCTAssertEqual(scopedDiff.components(separatedBy: "diff --git").count - 1, 1)
    }
}
