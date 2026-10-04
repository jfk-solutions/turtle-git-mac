import XCTest
@testable import TurtleGitCore

final class CommitFileModeTests: XCTestCase {
    func testExplicitAddModesSurviveCheckedCommitWithLaterWorkingEditsAndUncheckedStaging() async throws {
        for mode in [WorkingFileAddMode.executable, .symlink] {
            let (root, repository, retainedPath) = try await GitPatchTests().fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("retain staged contents\n".utf8).write(to: root.appendingPathComponent(retainedPath))
            try await repository.stage([retainedPath])
            let retained = try await repository.run(["ls-files", "--stage", "-z", "--", retainedPath]).stdout
            let path = ":(glob)新,\nfile"
            let file = root.appendingPathComponent(path)
            try Data("first-target".utf8).write(to: file)
            let permissions = mode == .executable ? 0o645 : 0o644
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
            try await repository.addWorkingFiles(paths: [path], mode: mode)
            let latest = Data("later-target 雪".utf8)
            try latest.write(to: file)
            _ = try await repository.commitSelected(message: "selected mode", paths: [path])
            let tree = try await repository.run(["ls-tree", "-z", "HEAD", "--", path]).stdout
            let blob = try await repository.run(["show", "HEAD:" + path]).stdout
            let index = try await repository.run(["ls-files", "--stage", "-z", "--", path]).stdout
            let afterRetained = try await repository.run(["ls-files", "--stage", "-z", "--", retainedPath]).stdout
            XCTAssertTrue(String(decoding: tree, as: UTF8.self).hasPrefix(mode.indexMode! + " "))
            XCTAssertTrue(String(decoding: index, as: UTF8.self).hasPrefix(mode.indexMode! + " "))
            XCTAssertEqual(blob, latest); XCTAssertEqual(try Data(contentsOf: file), latest)
            XCTAssertEqual(afterRetained, retained)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, permissions)
        }
    }
    func testUnbornAndParentAmendRetainExplicitIndexModes() async throws {
        for parentAmend in [false, true] {
            let (root, repository) = try await CommitSelectionTests().fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            if parentAmend {
                try Data("base\n".utf8).write(to: root.appendingPathComponent("base"))
                try await repository.stage(["base"]); _ = try await repository.commit(message: "first")
                try Data("second\n".utf8).write(to: root.appendingPathComponent("base"))
                try await repository.stage(["base"]); _ = try await repository.commit(message: "second")
            }
            try Data("target".utf8).write(to: root.appendingPathComponent("link"))
            try await repository.addWorkingFiles(paths: ["link"], mode: .symlink)
            var options = CommitOptions(); options.amend = parentAmend; options.amendDiffToLastCommit = false
            _ = try await repository.commitSelected(message: "link commit", paths: ["link"], options: options)
            let tree = try await repository.run(["ls-tree", "HEAD", "--", "link"]).text
            XCTAssertTrue(tree.hasPrefix("120000 "))
        }
    }
    func testUnstagedNativePermissionChangeStillUsesWorkingMode() async throws {
        let (root, repository, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(path).path)
        _ = try await repository.commitSelected(message: "native executable", paths: [path])
        let tree = try await repository.run(["ls-tree", "-z", "HEAD", "--", path]).stdout
        XCTAssertTrue(String(decoding: tree, as: UTF8.self).hasPrefix("100755 "))
    }
    func testStagedExecutableRemovalSurvivesLatestWorkingContentsAndNormalAddClearsOverride() async throws {
        let (root, repository, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try await repository.stage([path]); _ = try await repository.commit(message: "executable base")
        _ = try await repository.run(["update-index", "--chmod=-x", "--", path])
        let latest = Data("latest script\n".utf8); try latest.write(to: file)
        _ = try await repository.commitSelected(message: "index removes executable bit", paths: [path])
        let tree = try await repository.run(["ls-tree", "-z", "HEAD", "--", path]).stdout
        let blob = try await repository.run(["show", "HEAD:" + path]).stdout
        XCTAssertTrue(String(decoding: tree, as: UTF8.self).hasPrefix("100644 "))
        XCTAssertEqual(blob, latest)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o755)
        try await repository.addWorkingFiles(paths: [path])
        _ = try await repository.commitSelected(message: "normal add uses disk mode", paths: [path])
        let resetTree = try await repository.run(["ls-tree", "-z", "HEAD", "--", path]).stdout
        XCTAssertTrue(String(decoding: resetTree, as: UTF8.self).hasPrefix("100755 "))
    }
}
