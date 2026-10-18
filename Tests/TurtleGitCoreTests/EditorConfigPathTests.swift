import XCTest
@testable import TurtleGitCore

final class EditorConfigPathTests: XCTestCase {
    private let root = FileTransferPaths.fileURL("/private/work tree")
    func testReflectedPathWinsWithoutRequiringEitherLeaf() throws {
        let reflected = "/private/reflected/new [literal]/missing.txt"
        XCTAssertEqual(try MergeEditorConfigPath.fileURL(actualPath: "/temporary/input.tmp", reflectedName: reflected, root: root).path, reflected)
        XCTAssertEqual(try MergeEditorConfigPath.fileURL(actualPath: "", reflectedName: reflected, root: root).path, reflected)
    }
    func testEmptyReflectionFallsBackToActualAbsoluteOrRepositoryRelativePath() throws {
        XCTAssertEqual(try MergeEditorConfigPath.fileURL(actualPath: "Sources/file.txt", reflectedName: "", root: root).path, "/private/work tree/Sources/file.txt")
        XCTAssertEqual(try MergeEditorConfigPath.fileURL(actualPath: "/separate/output.txt", root: root).path, "/separate/output.txt")
    }
    func testInvalidReflectedMetadataFailsInsteadOfReadingUnrelatedActualConfig() {
        for reflected in ["relative/file.txt", "file:///private/file.txt", "\0/private/file.txt", "/private/file\0.txt"] {
            XCTAssertThrowsError(try MergeEditorConfigPath.fileURL(actualPath: "/temporary/input.tmp", reflectedName: reflected, root: root))
        }
        XCTAssertThrowsError(try MergeEditorConfigPath.fileURL(actualPath: "", root: root))
        XCTAssertThrowsError(try MergeEditorConfigPath.fileURL(actualPath: "bad\0path", root: root))
        XCTAssertThrowsError(try MergeEditorConfigPath.fileURL(actualPath: "file.txt", root: URL(string: "https://example.invalid")!))
    }
    func testLiteralUnicodeNewlineAndMetacharacterSpellingsStayExact() throws {
        for component in ["caf\u{e9} [*]\nfile.txt", "cafe\u{301} [*]\nfile.txt"] {
            let path = "/private/" + component
            let reflected = try MergeEditorConfigPath.fileURL(actualPath: "/irrelevant", reflectedName: path, root: root)
            XCTAssertTrue(reflected.path.utf8.elementsEqual(path.utf8))
            let actual = try MergeEditorConfigPath.fileURL(actualPath: component, root: root)
            XCTAssertTrue(actual.path.utf8.elementsEqual((root.path + "/" + component).utf8))
        }
    }
}
