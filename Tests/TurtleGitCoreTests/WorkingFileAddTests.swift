import XCTest
@testable import TurtleGitCore

final class WorkingFileAddTests: XCTestCase {
    func testForceAddIgnoredLiteralFilesAndBothIndexModesPreserveWorkingContents() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        _ = try await repository.run(["update-index", "--split-index"])
        try Data("staged change\n".utf8).write(to: root.appendingPathComponent(tracked)); try await repository.stage([tracked])
        let retained = try await repository.run(["ls-files", "--stage", "-z", "--", tracked]).stdout
        try Data("*.ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        for (offset, mode) in WorkingFileAddMode.allCases.enumerated() {
            let path = ":(glob)雪,\n\(offset).ignored"
            let bytes = Data([0, 255, 13, 10, UInt8(offset)])
            let url = root.appendingPathComponent(path)
            try bytes.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try await repository.addWorkingFiles(paths: [path, path], mode: mode)
            let staged = try await repository.run(["ls-files", "--stage", "-z", "--", path]).stdout
            XCTAssertTrue(String(decoding: staged, as: UTF8.self).hasPrefix((mode.indexMode ?? "100644") + " "))
            let blob = try await repository.run(["show", ":" + path]).stdout
            XCTAssertEqual(blob, bytes)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, .typeRegular)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o644)
        }
        let finalTracked = try await repository.run(["ls-files", "--stage", "-z", "--", tracked]).stdout
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(finalTracked, retained); XCTAssertEqual(finalHead, head)
    }
    func testInvalidMissingAndLockedSelectionsLeaveRealIndexExact() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent(".git/index"), original = try Data(contentsOf: index)
        try Data([42]).write(to: root.appendingPathComponent("new"))
        for paths in [[String](), ["../escape"], [".git/index"], ["new", "missing"]] {
            do { try await repository.addWorkingFiles(paths: paths); XCTFail("Invalid selection accepted") } catch {}
            XCTAssertEqual(try Data(contentsOf: index), original)
        }
        let lock = root.appendingPathComponent(".git/index.lock")
        try Data([99]).write(to: lock)
        do { try await repository.addWorkingFiles(paths: ["new"]); XCTFail("Existing lock overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: index), original); XCTAssertEqual(try Data(contentsOf: lock), Data([99]))
    }
    func testUnbornIndexAndDirectoryModeOverrides() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = GitRepository(root: root)
        _ = try await repository.run(["init", "-b", "main"])
        try Data([1]).write(to: root.appendingPathComponent("folder/file"))
        try await repository.addWorkingFiles(paths: ["folder"], mode: .executable)
        let staged = try await repository.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertTrue(String(decoding: staged, as: UTF8.self).hasPrefix("100644 "), "Upstream leaves directory children’s modes unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }
    func testLinkedWorktreeUpdatesOnlyItsOwnIndex() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        let linked = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: root) }
        _ = try await repository.run(["worktree", "add", "-b", "add-linked", linked.path])
        let original = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("target\n".utf8).write(to: linked.appendingPathComponent("link"))
        let other = GitRepository(root: linked)
        try await other.addWorkingFiles(paths: ["link"], mode: .symlink)
        let staged = try await other.run(["ls-files", "--stage", "-z", "--", "link"]).stdout
        XCTAssertTrue(String(decoding: staged, as: UTF8.self).hasPrefix("120000 "))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), original)
    }
}
