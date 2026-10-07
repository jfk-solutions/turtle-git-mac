import XCTest
@testable import TurtleGitCore

final class WorkingFileExportTests: XCTestCase {
    func testWorkingOpenReturnsActualLiteralPathAndRefusesMissingDirectoriesMetadataAndBare() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "open :(glob)* 雪\n.bin", url = root.appendingPathComponent(path), bytes = Data([0xff, 0, 13, 10])
        try bytes.write(to: url)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let location = try await repo.workingFileOpenLocation(path: path); XCTAssertEqual(location, url)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: path)
        let linked = try await repo.workingFileOpenLocation(path: "link"); XCTAssertEqual(linked, root.appendingPathComponent("link"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: true)
        for invalid in ["missing", "directory", "../outside", ".git/index", "/absolute"] {
            do { _ = try await repo.workingFileOpenLocation(path: invalid); XCTFail("Invalid working open accepted: " + invalid) } catch {}
        }
        let bare = root.appendingPathComponent("bare.git"); _ = try await repo.run(["init", "--bare", bare.path])
        do { _ = try await GitRepository(root: bare).workingFileOpenLocation(path: "config"); XCTFail("Bare working open accepted") } catch RevisionComparisonFailure.selection {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
    }
    func testWorkingSaveAsPreservesBinaryBytesPermissionsAndIndexAndRejectsAliases() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        let destination = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: destination) }
        let path = "save 雪\n.bin", file = root.appendingPathComponent(path), bytes = Data([0, 255, 13, 10])
        try bytes.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try await repo.stage([path]); let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let working = Data([255, 0, 3]); try working.write(to: file)
        try Data("old".utf8).write(to: destination)
        try await repo.saveWorkingFile(path: path, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), working)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(try Data(contentsOf: file), working); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        for target in [file, alias, root.appendingPathComponent(".git/config")] {
            do { try await repo.saveWorkingFile(path: path, to: target); XCTFail("Unsafe save accepted") } catch {}
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        try await repo.saveWorkingFile(path: "link", to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), working)
        let token = OperationCancellation(); token.cancel()
        do { try await repo.saveWorkingFile(path: path, to: destination, cancellation: token); XCTFail("Cancelled save accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), working)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }

    func testHistoricalExportPinsRevisionAndPreservesLiteralBytesHierarchyAndRepository() async throws {
        let manager = FileManager.default
        let (root, repo, _) = try await GitPatchTests().fixture()
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root); try? manager.removeItem(at: folder) }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let path = "nested/:(glob)* 雪\n.bin", link = "nested/link"
        let bytes = Data([0, 255, 239, 187, 191, 13, 10])
        try bytes.write(to: root.appendingPathComponent(path))
        try manager.createSymbolicLink(atPath: root.appendingPathComponent(link).path, withDestinationPath: "missing-target")
        try await repo.stage([path, link]); _ = try await repo.run(["commit", "-m", "export blobs"])
        func file(_ path: String, _ action: String = "M", submodule: Bool = false) -> CommitFile {
            CommitFile(path: path, oldPath: nil, action: action, added: nil, removed: nil, hasStatistics: false, isSubmodule: submodule)
        }
        let export = try await repo.prepareHistoricalExport(revision: "HEAD", files: [file(path), file("deleted", "D"), file(link), file("module", submodule: true), file(path)], to: folder)
        XCTAssertEqual(export.paths, [path, link])
        try Data([42]).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.run(["commit", "-m", "later bytes"])
        try Data([43]).write(to: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        try manager.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data([99]).write(to: folder.appendingPathComponent(path))
        for selected in export.paths { try await repo.exportHistoricalFile(export, path: selected) }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(path)), bytes)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(link)), Data("missing-target".utf8))
        XCTAssertEqual(try manager.attributesOfItem(atPath: folder.appendingPathComponent(link).path)[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data([43]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(finalHead, head)
        do { try await repo.exportHistoricalFile(export, path: "unselected"); XCTFail("Unselected export") } catch {}
        do { _ = try await repo.prepareHistoricalExport(revision: "HEAD", files: [file(path)], to: root); XCTFail("Source overwrite") } catch WorkingFileExportFailure.source {}
        do { _ = try await repo.prepareHistoricalExport(revision: "HEAD", files: [file(".git/index")], to: folder); XCTFail("Metadata export") } catch {}
    }
    func testHistoricalFailureCanContinueAndDestinationAliasCannotEscape() async throws {
        let manager = FileManager.default
        let (root, repo, path) = try await GitPatchTests().fixture()
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { for url in [root, folder, outside] { try? manager.removeItem(at: url) } }
        for url in [folder, outside] { try manager.createDirectory(at: url, withIntermediateDirectories: true) }
        func file(_ path: String) -> CommitFile { CommitFile(path: path, oldPath: nil, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false) }
        let export = try await repo.prepareHistoricalExport(revision: "HEAD", files: [file("absent"), file(path)], to: folder)
        do { try await repo.exportHistoricalFile(export, path: "absent"); XCTFail("Absent blob accepted") } catch {}
        try await repo.exportHistoricalFile(export, path: path)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(path)), try Data(contentsOf: root.appendingPathComponent(path)))
        try manager.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data([77]).write(to: root.appendingPathComponent("nested/file")); try await repo.stage(["nested/file"])
        _ = try await repo.run(["commit", "-m", "nested historical blob"])
        let nested = try await repo.prepareHistoricalExport(revision: "HEAD", files: [file("nested/file")], to: folder)
        try manager.createSymbolicLink(at: folder.appendingPathComponent("nested"), withDestinationURL: outside)
        do { try await repo.exportHistoricalFile(nested, path: "nested/file"); XCTFail("Escaped folder accepted") } catch WorkingFileExportFailure.location {}
        XCTAssertFalse(manager.fileExists(atPath: outside.appendingPathComponent("file").path))
    }
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
