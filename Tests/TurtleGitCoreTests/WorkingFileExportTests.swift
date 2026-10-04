import XCTest
@testable import TurtleGitCore

final class WorkingFileExportTests: XCTestCase {
    func testWorkingContentsHierarchyOverwriteAndIndexRemainExact() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: destination) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let bytes = Data([0, 255, 239, 187, 191, 13, 10])
        try bytes.write(to: root.appendingPathComponent(path))
        let untracked = "nested/雪.bin"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try bytes.write(to: root.appendingPathComponent(untracked))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(untracked).path)
        let first = try await repo.exportWorkingFiles(paths: [path, untracked, "nested", path], to: destination)
        XCTAssertEqual(first, 2)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(untracked)), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(untracked).path)[.posixPermissions] as? Int, 0o755)
        try Data([42]).write(to: destination.appendingPathComponent(path))
        _ = try await repo.exportWorkingFiles(paths: [path], to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(path)), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(finalHead, head)
    }
    func testRejectsSourceOverwriteAndMetadataOrEscapingPaths() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        for (paths, destination) in [([path], root), (["../outside"], root), ([".git/index"], root), ([path], root.appendingPathComponent(".git"))] {
            do { _ = try await repo.exportWorkingFiles(paths: paths, to: destination); XCTFail("Unsafe export accepted") } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), original)
    }
    func testRejectsDestinationParentSymlinkAndReplacesLeafWithoutFollowingIt() async throws {
        let manager = FileManager.default
        let (root, repo, path) = try await GitPatchTests().fixture()
        let destination = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { for url in [root, destination, outside] { try? manager.removeItem(at: url) } }
        for url in [destination, outside, root.appendingPathComponent("nested")] { try manager.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data([1]).write(to: root.appendingPathComponent("nested/file"))
        try manager.createSymbolicLink(at: destination.appendingPathComponent("nested"), withDestinationURL: outside)
        do { _ = try await repo.exportWorkingFiles(paths: ["nested/file"], to: destination); XCTFail("Escaped destination") } catch WorkingFileExportFailure.location {}
        XCTAssertFalse(manager.fileExists(atPath: outside.appendingPathComponent("file").path))
        try manager.removeItem(at: destination.appendingPathComponent("nested"))
        try manager.createDirectory(at: destination.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: destination.appendingPathComponent("nested"), withDestinationURL: destination.appendingPathComponent(".git"))
        do { _ = try await repo.exportWorkingFiles(paths: ["nested/file"], to: destination); XCTFail("Metadata destination alias accepted") } catch WorkingFileExportFailure.location {}
        XCTAssertFalse(manager.fileExists(atPath: destination.appendingPathComponent(".git/file").path))
        let protected = outside.appendingPathComponent("protected")
        try Data([99]).write(to: protected)
        let leaf = destination.appendingPathComponent(path)
        try manager.createDirectory(at: leaf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: leaf, withDestinationURL: protected)
        _ = try await repo.exportWorkingFiles(paths: [path], to: destination)
        XCTAssertEqual(try Data(contentsOf: protected), Data([99]))
        XCTAssertEqual(try Data(contentsOf: leaf), try Data(contentsOf: root.appendingPathComponent(path)))
        XCTAssertEqual(try manager.attributesOfItem(atPath: leaf.path)[.type] as? FileAttributeType, .typeRegular)
    }
    func testSymbolicSourceExportsTargetContentsAndMissingSourceReportsFailure() async throws {
        let manager = FileManager.default
        let (root, repo, path) = try await GitPatchTests().fixture()
        let destination = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root); try? manager.removeItem(at: destination) }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent(path))
        _ = try await repo.exportWorkingFiles(paths: ["link"], to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("link")), try Data(contentsOf: root.appendingPathComponent(path)))
        XCTAssertEqual(try manager.attributesOfItem(atPath: destination.appendingPathComponent("link").path)[.type] as? FileAttributeType, .typeRegular)
        do { _ = try await repo.exportWorkingFiles(paths: ["missing"], to: destination); XCTFail("Missing source accepted") } catch {}
    }
}
