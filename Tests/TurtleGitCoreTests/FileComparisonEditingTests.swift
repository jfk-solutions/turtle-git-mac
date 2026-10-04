import XCTest
@testable import TurtleGitCore

final class FileComparisonEditingTests: XCTestCase {
    func testAlignedEditsExcludeGapsAndPreserveEndingsAndEOF() throws {
        let aligned = FileComparisonAlignment(base: "removed\r\nkeep\r\nend", destination: "keep\r\nend")
        let cells = aligned.rows.map(\.destination)
        let gap = try FileComparisonEditing.applying("", range: NSRange(location: 0, length: 1), cells: cells)
        XCTAssertEqual(gap.text, "keep\r\nend")
        let inserted = try FileComparisonEditing.applying("insert\n", range: NSRange(location: 0, length: 0), cells: cells)
        XCTAssertEqual(inserted.text, "insert\r\nkeep\r\nend")
        let replacement = try FileComparisonEditing.applying("X", range: NSRange(location: 2, length: 3), cells: cells)
        XCTAssertEqual(replacement.text, "kX\r\nend")
        let ending = try FileComparisonEditing.applying("", range: NSRange(location: 5, length: 1), cells: cells)
        XCTAssertEqual(ending.text, "keepend")
        let eof = try FileComparisonEditing.applying("!", range: NSRange(location: 9, length: 0), cells: cells)
        XCTAssertEqual(eof.text, "keep\r\nend!")
        XCTAssertEqual(FileComparisonEditing.displayOffset(sourceOffset: 9, cells: cells), 9)
        XCTAssertThrowsError(try FileComparisonEditing.applying("oops", range: NSRange(location: 100, length: 1), cells: cells))
    }
    func testSavingPreservesBOMEncodingPermissionsAndIndexAndSupportsReverseSide() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        for (prefix, encoding) in [(Data([0xef, 0xbb, 0xbf]), String.Encoding.utf8), (Data([0xff, 0xfe]), .utf16LittleEndian), (Data([0xfe, 0xff]), .utf16BigEndian)] {
            let location = root.appendingPathComponent(path)
            try (prefix + "work\r\nend".data(using: encoding)!).write(to: location)
            try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: location.path)
            let snapshot = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree)
            let document = try await repo.comparisonFile(snapshot, path: path)
            let saved = try await repo.saveComparisonFile(snapshot, document: document, base: false, text: "edited 雪\r\nend")
            XCTAssertEqual(saved.destination.text, "edited 雪\r\nend")
            XCTAssertEqual(try Data(contentsOf: location), prefix + "edited 雪\r\nend".data(using: encoding)!)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: location.path)[.posixPermissions] as? NSNumber)?.intValue, 0o751)
            let reverse = try await repo.revisionComparison(from: .workingTree, to: .revision("HEAD"))
            let reversed = try await repo.comparisonFile(reverse, path: path)
            let updated = try await repo.saveComparisonFile(reverse, document: reversed, base: true, text: "reverse")
            XCTAssertEqual(updated.base.text, "reverse")
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
    }
    func testExternalTextModeAndSymlinkChangesAreRejectedWithoutOverwrites() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent(path)
        try Data("working".utf8).write(to: location)
        let snapshot = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree)
        let document = try await repo.comparisonFile(snapshot, path: path)
        try Data("external".utf8).write(to: location)
        do { _ = try await repo.saveComparisonFile(snapshot, document: document, base: false, text: "overwrite"); XCTFail() } catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try String(contentsOf: location), "external")
        try document.destination.bytes.write(to: location)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: location.path)
        do { _ = try await repo.saveComparisonFile(snapshot, document: document, base: false, text: "overwrite"); XCTFail() } catch FileComparisonEditFailure.changed {}
        let readOnly = try await repo.comparisonFile(snapshot, path: path)
        do { _ = try await repo.saveComparisonFile(snapshot, document: readOnly, base: false, text: "overwrite"); XCTFail() } catch FileComparisonEditFailure.readOnly {}
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createSymbolicLink(atPath: location.path, withDestinationPath: "/outside/repository")
        do { _ = try await repo.saveComparisonFile(snapshot, document: document, base: false, text: "overwrite"); XCTFail() } catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: location.path), "/outside/repository")
    }
}
