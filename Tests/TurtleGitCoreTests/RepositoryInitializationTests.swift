import XCTest
@testable import TurtleGitCore

final class RepositoryInitializationTests: XCTestCase {
    func parent() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testNormalCreationHonorsDefaultBranchAndTemplatesWithoutChangingFiles() async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let template = parent.appendingPathComponent("template"), target = parent.appendingPathComponent("new 雪 repository")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("template description\n".utf8).write(to: template.appendingPathComponent("description"))
        try Data("keep this\n".utf8).write(to: target.appendingPathComponent("notes.txt"))
        let wrapper = parent.appendingPathComponent("git-test")
        let quoted = "'" + template.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try Data(("#!/bin/sh\nexport GIT_TEMPLATE_DIR=" + quoted + "\nexec /usr/bin/git -c init.defaultBranch=fixture-default \"$@\"\n").utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        _ = try await GitRepository(root: parent, executable: wrapper).initialize(at: target, bare: false)
        let repo = GitRepository(root: target), branch = try await repo.branch(), bare = try await repo.isBare()
        let history = try await repo.history(), status = try await repo.status()
        XCTAssertEqual(branch, "fixture-default"); XCTAssertFalse(bare); XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(status.map(\.path), ["notes.txt"])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("notes.txt")), "keep this\n")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent(".git/description")), "template description\n")
    }
    func testBareWarningRequiresConfirmationAndPreservesOccupiedContents() async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("archive.git")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let note = target.appendingPathComponent("keep.txt"); try Data("existing\n".utf8).write(to: note)
        let runner = GitRepository(root: parent)
        do { _ = try await runner.initialize(at: target, bare: true); XCTFail("Bare warning was bypassed") }
        catch InitializationFailure.confirmationRequired(let warnings) { XCTAssertEqual(warnings, [.nonemptyBare]) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("HEAD").path))
        _ = try await runner.initialize(at: target, bare: true, confirmedWarnings: [.nonemptyBare])
        let repo = GitRepository(root: target), bare = try await repo.isBare(), root = try await repo.discoverRoot(), history = try await repo.history()
        XCTAssertTrue(bare); XCTAssertEqual(root.resolvingSymlinksInPath(), target.resolvingSymlinksInPath()); XCTAssertTrue(history.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".git").path))
        XCTAssertEqual(try String(contentsOf: note), "existing\n")
    }
    func testReinitializePreservesHeadIndexWorktreeAndConfiguration() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("index\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("working\n".utf8).write(to: root.appendingPathComponent(path))
        _ = try await repo.run(["config", "turtlegit.fixture", "preserve"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text, index = try await repo.diff(staged: true), working = try await repo.diff()
        _ = try await repo.initialize(at: root, bare: false)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text, afterIndex = try await repo.diff(staged: true), afterWorking = try await repo.diff()
        let config = try await repo.run(["config", "--get", "turtlegit.fixture"]).text
        XCTAssertEqual(head, afterHead); XCTAssertEqual(index, afterIndex); XCTAssertEqual(working, afterWorking); XCTAssertEqual(config, "preserve\n")
    }
    func testNestedBareDiscoveryAndPushFetchHistoryWithoutWorkingTree() async throws {
        let (source, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let bare = source.appendingPathComponent("nested bare 雪\n.git")
        _ = try await repo.initialize(at: bare, bare: true)
        let store = GitRepository(root: bare), discovered = try await store.discoverRoot()
        XCTAssertEqual(discovered.resolvingSymlinksInPath(), bare.resolvingSymlinksInPath())
        let inside = try await GitRepository(root: bare.appendingPathComponent("objects")).discoverRoot()
        XCTAssertEqual(inside.resolvingSymlinksInPath(), bare.resolvingSymlinksInPath())
        _ = try await repo.run(["remote", "add", "local-bare", bare.path])
        var push = PushOptions(); push.remote = "local-bare"; push.source = "main"; push.destination = "main"
        _ = try await repo.push(push)
        let history = try await store.history(), branch = try await store.branch()
        // The bare repository retains Git's configured initial symbolic branch.
        var all = HistoryOptions(); all.allBranches = true
        let allHistory = try await store.history(options: all)
        XCTAssertEqual(allHistory.first?.subject, "base")
        XCTAssertEqual(history.count, branch == "main" ? 1 : 0)
        _ = try await store.run(["remote", "add", "source", source.path])
        var fetch = FetchOptions(); fetch.remote = "source"; fetch.namedRemoteFetchAll = true
        _ = try await store.fetch(fetch)
        let remote = try await store.run(["rev-parse", "refs/remotes/source/main"]).text, head = try await repo.run(["rev-parse", "HEAD"]).text
        XCTAssertEqual(remote, head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.appendingPathComponent("index").path))
    }
    func testSpecialFolderClassificationAndInvalidDestinationDoNotCreateMetadata() async throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        XCTAssertEqual(try RepositoryInitialization.warnings(for: alias, bare: false, specialFolders: [parent]), [.specialFolder])
        XCTAssertTrue(try RepositoryInitialization.warnings(for: parent.appendingPathComponent("child"), bare: false, specialFolders: [parent]).isEmpty)
        XCTAssertTrue(try RepositoryInitialization.warnings(for: FileManager.default.homeDirectoryForCurrentUser, bare: false).contains(.specialFolder))
        XCTAssertTrue(RepositoryInitialization.defaultsToBare(parent.appendingPathComponent("archive.git")))
        XCTAssertFalse(RepositoryInitialization.defaultsToBare(parent.appendingPathComponent("archive")))
        let file = parent.appendingPathComponent("file"); try Data("keep\n".utf8).write(to: file)
        do { _ = try await GitRepository(root: parent).initialize(at: file, bare: false); XCTFail("File accepted as directory") } catch InitializationFailure.destination {}
        XCTAssertEqual(try String(contentsOf: file), "keep\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path))
    }
}
