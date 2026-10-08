import XCTest
@testable import TurtleGitCore

final class TemporaryFilesTests: XCTestCase {
    func fixture(_ body: (URL, TemporaryFileStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit.Temp.Tests." + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory, TemporaryFileStore(root: directory.appendingPathComponent("owned")))
    }
    func testPrivatePreparationAndMissingClear() throws {
        try fixture { _, store in
            XCTAssertEqual(try store.clear(), 0); XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
            try store.prepare()
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }
    func testClearNestedReadOnlyFilesAndGravatarPreservesOutsideSymlinkTarget() throws {
        try fixture { directory, store in
            try store.prepare()
            let cache = store.root.appendingPathComponent("TurtleGit-Gravatar/nested")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let image = cache.appendingPathComponent("image"); try Data("avatar".utf8).write(to: image)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: image.path)
            let outside = directory.appendingPathComponent("repository"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let sentinel = outside.appendingPathComponent("file"); try Data("keep".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("link"), withDestinationURL: outside)
            XCTAssertEqual(try store.clear(), 0); XCTAssertEqual(try String(contentsOf: sentinel), "keep")
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.path)); XCTAssertEqual(try store.clear(), 0)
        }
    }
    func testSubstitutedRootLinkCannotDeleteAnotherDirectory() throws {
        try fixture { directory, store in
            let outside = directory.appendingPathComponent("other"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let sentinel = outside.appendingPathComponent("file"); try Data("keep".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: store.root, withDestinationURL: outside)
            XCTAssertThrowsError(try store.clear()); XCTAssertThrowsError(try store.prepare())
            XCTAssertEqual(try String(contentsOf: sentinel), "keep")
        }
    }
    func testProductionPreviewLivesInManagedRootAndKeepsExactBytes() throws {
        let preview = try UnifiedDiffPreview.create(Data("雪\r\npatch".utf8)); defer { preview.discard() }
        XCTAssertEqual(preview.directory.deletingLastPathComponent().standardizedFileURL, TurtleGitTemporaryStorage.defaultRoot.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: preview.file), Data("雪\r\npatch".utf8))
    }
}
