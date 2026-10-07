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
