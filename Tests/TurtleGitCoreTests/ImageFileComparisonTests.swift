import XCTest
@testable import TurtleGitCore

final class ImageFileComparisonTests: XCTestCase {
    func testEmptySidesRemainExplicitImageViewerInputs() throws {
        let document = try ImageFileComparison(base: nil, destination: nil).read()
        XCTAssertTrue(document.base.bytes.isEmpty); XCTAssertTrue(document.destination.bytes.isEmpty)
        XCTAssertNil(ImageComparisonDocument(document))
        let explicit = ImageComparisonDocument(base: nil, destination: nil)
        XCTAssertNil(explicit.base); XCTAssertNil(explicit.destination)
    }
    func testSingleDuplicateAndSymlinkInputsReadOriginalBytesWithoutWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-image-file-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.dat"), link = root.appendingPathComponent("link.dat")
        let bytes = Data([0, 1, 255, 48, 0])
        try bytes.write(to: file); try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.lastPathComponent)
        let single = try ImageFileComparison(base: nil, destination: file).read()
        XCTAssertTrue(single.base.bytes.isEmpty); XCTAssertEqual(single.destination.bytes, bytes)
        let duplicate = try ImageFileComparison(base: file, destination: file).read()
        XCTAssertEqual(duplicate.base.bytes, duplicate.destination.bytes)
        let linked = try ImageFileComparison(base: link, destination: file).read()
        XCTAssertEqual(linked.base.bytes, bytes); XCTAssertEqual(linked.base.path, link.path)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), file.lastPathComponent)
    }
    func testNonFileAndDirectoryInputsAreRejected() throws {
        XCTAssertThrowsError(try ImageFileComparison(base: URL(string: "https://example.invalid/image")!, destination: nil))
        XCTAssertThrowsError(try ImageFileComparison(base: FileManager.default.temporaryDirectory, destination: nil).read())
    }
}
