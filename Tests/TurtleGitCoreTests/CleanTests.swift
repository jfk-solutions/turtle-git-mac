import XCTest
@testable import TurtleGitCore

final class CleanTests: XCTestCase {
    func testModesQuotedPathsDirectoriesAndNestedRepositoryPreserveBytes() async throws {
        let (root, fixture, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixture.executable)
        try Data("*.ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try await repo.stage([".gitignore"]); _ = try await repo.commit(message: "clean fixture")
        let special = ":(glob)* 雪\n\"\\.txt"
        let bytes = Data([0, 255, 13, 10])
        for path in [special, "secret.ignored"] { try bytes.write(to: root.appendingPathComponent(path)) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try bytes.write(to: root.appendingPathComponent("folder/file"))
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let child = GitRepository(root: nested, executable: repo.executable)
        _ = try await child.run(["init", "-b", "main"])
        try bytes.write(to: nested.appendingPathComponent("kept"))
        try Data("modified tracked\n".utf8).write(to: root.appendingPathComponent(tracked))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let all = try await repo.cleanPreview()
        XCTAssertEqual(Set(all.candidates), [special, "secret.ignored", "folder/"])
        let ordinary = try await repo.cleanPreview(options: CleanOptions(type: .nonIgnored))
        XCTAssertEqual(Set(ordinary.candidates), [special, "folder/"])
        let ignored = try await repo.cleanPreview(options: CleanOptions(type: .ignored))
        XCTAssertEqual(ignored.candidates, ["secret.ignored"])
        let files = try await repo.cleanPreview(options: CleanOptions(directories: false))
        XCTAssertEqual(Set(files.candidates), [special, "secret.ignored"])
        let unmanaged = try await repo.cleanPreview(options: CleanOptions(unmanagedRepositories: true))
        XCTAssertEqual(Set(unmanaged.candidates), [special, "secret.ignored", "folder/", "nested/"])
        let scoped = try await repo.cleanPreview(paths: [special])
        XCTAssertEqual(scoped.candidates, [special], "Pathspec-looking names must remain literal")
        _ = try await repo.run(["config", "core.quotepath", "false"])
        let unquotedConfig = try await repo.cleanPreview(paths: [special]); XCTAssertEqual(unquotedConfig.candidates, [special])
        _ = try await repo.run(["config", "--unset", "core.quotepath"])
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(afterHead, head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
        for path in [special, "secret.ignored", "folder/file", "nested/kept"] { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(tracked)), Data("modified tracked\n".utf8))
    }
    private func executionFixture() async throws -> (URL, GitRepository, String) {
        let (root, fixture, path) = try await GitPatchTests().fixture()
        return (root, GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixture.executable), path)
    }
    func testActualTrashRecoversBinaryDirectoryAndSymlinkWithoutIndexChanges() async throws {
        let (root, repo, tracked) = try await executionFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitCleanOutside-" + UUID().uuidString)
        try Data("outside preserved\n".utf8).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
        let name = ":(glob)* raw 雪\n.txt", bytes = Data([0, 255, 13, 10])
        try bytes.write(to: root.appendingPathComponent(name))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try bytes.write(to: root.appendingPathComponent("folder/raw"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: outside.path)
        try Data("staged tracked\n".utf8).write(to: root.appendingPathComponent(tracked)); try await repo.stage([tracked])
        try Data("later tracked\n".utf8).write(to: root.appendingPathComponent(tracked))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let plan = try await repo.cleanPreview()
        let result = try await repo.executeClean(plan)
        defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(Set(result.removedPaths), [name, "folder/", "link"]); XCTAssertEqual(result.trashedFiles.count, 3)
        for (path, recovered) in zip(result.removedPaths, result.trashedFiles) {
            if path == "link" { XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: recovered.path), outside.path) }
            else { XCTAssertEqual(try Data(contentsOf: path == "folder/" ? recovered.appendingPathComponent("raw") : recovered), bytes) }
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside preserved\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(afterHead, head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(tracked)), Data("later tracked\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }
    func testPermanentIgnoredAndExplicitNestedCleanupPreserveTrackedIndex() async throws {
        let (root, repo, _) = try await executionFixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("*.ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore")); try await repo.stage([".gitignore"])
        try Data("remove\n".utf8).write(to: root.appendingPathComponent("secret.ignored"))
        try Data("retain\n".utf8).write(to: root.appendingPathComponent("ordinary"))
        let nested = root.appendingPathComponent("nested"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        _ = try await GitRepository(root: nested, executable: repo.executable).run(["init", "-b", "main"])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let ignored = try await repo.cleanPreview(options: CleanOptions(type: .ignored))
        let first = try await repo.executeClean(ignored, permanently: true)
        XCTAssertEqual(first.removedPaths, ["secret.ignored"]); XCTAssertTrue(first.trashedFiles.isEmpty)
        let protected = try await repo.cleanPreview(paths: ["nested"]); XCTAssertTrue(protected.candidates.isEmpty)
        let explicit = try await repo.cleanPreview(options: CleanOptions(unmanagedRepositories: true), paths: ["nested"])
        let second = try await repo.executeClean(explicit, permanently: true); XCTAssertEqual(second.removedPaths, ["nested/"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("ordinary")), Data("retain\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testChangedContentTrackedCandidatesForeignRootAndLockRefuseExecution() async throws {
        let (root, repo, _) = try await executionFixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        let file = root.appendingPathComponent("folder/raw"); try Data("a\n".utf8).write(to: file)
        let plan = try await repo.cleanPreview()
        try Data("b\n".utf8).write(to: file)
        do { _ = try await repo.executeClean(plan, permanently: true); XCTFail("Changed directory content accepted") } catch CleanFailure.changed {}
        let fresh = try await repo.cleanPreview()
        let foreign = GitRepository(root: root.deletingLastPathComponent(), executable: repo.executable)
        do { _ = try await foreign.executeClean(fresh, permanently: true); XCTFail("Foreign plan accepted") } catch CleanFailure.changed {}
        let lock = root.appendingPathComponent(".git/index.lock"), lockBytes = Data("owned lock\n".utf8)
        try lockBytes.write(to: lock)
        do { _ = try await repo.executeClean(fresh, permanently: true); XCTFail("Existing lock accepted") } catch CleanFailure.locked {}
        XCTAssertEqual(try Data(contentsOf: lock), lockBytes); try FileManager.default.removeItem(at: lock)
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await repo.executeClean(fresh, permanently: true, cancellation: cancellation); XCTFail("Canceled execution accepted") } catch {}
        try await repo.stage(["folder/raw"])
        do { _ = try await repo.executeClean(fresh, permanently: true); XCTFail("Newly tracked file removed") } catch CleanFailure.changed {}
        XCTAssertEqual(try Data(contentsOf: file), Data("b\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }
    func testPartialCancellationAndTrashFailureReportCompletedPathsWithoutFallback() async throws {
        let (root, repo, _) = try await executionFixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let plan = try await repo.cleanPreview()
        do {
            _ = try await repo.executeClean(plan, permanently: false, cancellation: nil, removal: { _, permanent in
                XCTAssertFalse(permanent)
                throw NSError(domain: "OwnedCleanTrashFailure", code: 1)
            }); XCTFail("Trash error ignored")
        } catch let failure as CleanExecutionFailure {
            XCTAssertTrue(failure.result.removedPaths.isEmpty); XCTAssertFalse(failure.cancelled); XCTAssertEqual(failure.failedPath, "a")
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a")), Data("a".utf8))
        let cancellation = OperationCancellation()
        do {
            _ = try await repo.executeClean(plan, permanently: true, cancellation: cancellation, removal: { location, _ in
                try FileManager.default.removeItem(at: location); cancellation.cancel(); return nil
            }); XCTFail("Mid-execution cancellation ignored")
        } catch let failure as CleanExecutionFailure {
            XCTAssertTrue(failure.cancelled); XCTAssertEqual(failure.result.removedPaths, ["a"]); XCTAssertEqual(failure.failedPath, "b")
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("b")), Data("b".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }
    func testBareInvalidScopeAndCancellationRefusePreview() async throws {
        let (root, fixture, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixture.executable)
        for path in ["../outside", "/tmp/outside", ".git", "folder/.git/config", "bad\0path", ""] {
            do { _ = try await repo.cleanPreview(paths: [path]); XCTFail("Invalid scope accepted") } catch CleanFailure.path {}
        }
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await repo.cleanPreview(cancellation: cancellation); XCTFail("Canceled preview accepted") } catch {}
        let bare = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", "--", root.path, bare.path])
        do { _ = try await GitRepository(root: bare, executable: repo.executable).cleanPreview(); XCTFail("Bare preview accepted") } catch CleanFailure.bare {}
        var options = CleanOptions(unmanagedRepositories: true); options.directories = false
        XCTAssertFalse(options.unmanagedRepositories)
    }
}
