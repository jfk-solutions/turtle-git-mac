import XCTest
@testable import TurtleGitCore

final class CommitFileDropTests: XCTestCase {
    func testFilesFoldersLiteralNamesIgnoredFailuresAndRetainedIndex() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        try Data("already staged\n".utf8).write(to: root.appendingPathComponent(tracked)); try await repository.stage([tracked])
        let retained = try await repository.run(["ls-files", "--stage", "-z", "--", tracked]).stdout
        try Data("*.ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let literal = ":(glob)雪,\nfile.txt", ignored = "never.ignored"
        for path in [literal, ignored] { try Data(path.utf8).write(to: root.appendingPathComponent(path)) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("folder bytes".utf8).write(to: root.appendingPathComponent("folder/item.txt"))
        let result = try await repository.addDroppedCommitFiles([root.appendingPathComponent(ignored), root.appendingPathComponent(literal), root.appendingPathComponent(literal), root.appendingPathComponent("folder")])
        XCTAssertEqual(result.map(\.path), [ignored, literal, "folder"])
        XCTAssertEqual(result.map(\.added), [false, true, true]); XCTAssertNotNil(result[0].error); XCTAssertTrue(result[2].directory)
        let literalBlob = try await repository.run(["show", ":" + literal]).stdout
        XCTAssertEqual(literalBlob, Data(literal.utf8))
        let stagedIgnored = try await repository.run(["ls-files", "-z", "--", ignored]).stdout
        XCTAssertTrue(stagedIgnored.isEmpty)
        let finalRetained = try await repository.run(["ls-files", "--stage", "-z", "--", tracked]).stdout
        XCTAssertEqual(finalRetained, retained)
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(finalHead, head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(literal)), Data(literal.utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("folder/item.txt")), Data("folder bytes".utf8))
    }
    func testOtherRepositoriesNestedRootsMetadataAndSymlinkParentsAreIgnored() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathExtension("other")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let other = GitRepository(root: external); _ = try await other.run(["init", "-b", "main"])
        try Data("outside".utf8).write(to: external.appendingPathComponent("file"))
        let nested = root.appendingPathComponent("nested"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try await GitRepository(root: nested).run(["init", "-b", "main"])
        try Data("nested".utf8).write(to: nested.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("leaf-link"), withDestinationURL: external.appendingPathComponent("file"))
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let refused = try await repository.addDroppedCommitFiles([external.appendingPathComponent("file"), nested, nested.appendingPathComponent("file"), root.appendingPathComponent(".git/config"), root.appendingPathComponent("escape/file"), URL(string: "https://example.invalid/file")!])
        XCTAssertTrue(refused.isEmpty); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        let allowed = try await repository.addDroppedCommitFiles([root.appendingPathComponent("leaf-link")]); XCTAssertEqual(allowed.map(\.path), ["leaf-link"])
        let blob = try await repository.run(["show", ":leaf-link"]).stdout
        XCTAssertEqual(blob, Data(external.appendingPathComponent("file").path.utf8))
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("file")), Data("outside".utf8))
    }
    func testRootDropAndPrecancel() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("new".utf8).write(to: root.appendingPathComponent("new.txt"))
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index")), cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await repository.addDroppedCommitFiles([root], cancellation: cancellation); XCTFail("Expected cancellation") } catch is OperationCancellationFailure { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        let result = try await repository.addDroppedCommitFiles([root]); XCTAssertEqual(result.map(\.path), ["."])
        let staged = try await repository.run(["show", ":new.txt"]).stdout; XCTAssertEqual(staged, Data("new".utf8))
    }
}
