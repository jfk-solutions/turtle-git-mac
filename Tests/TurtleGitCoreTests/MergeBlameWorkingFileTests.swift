import XCTest
@testable import TurtleGitCore

final class MergeBlameWorkingFileTests: XCTestCase {
    private var engine: SubversionMergeConfiguration {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var value = SubversionMergeConfiguration(executable: root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"), runtimeRoot: root.appendingPathComponent("build/git-runtime/Git"))
        value.blame = true
        return value
    }
    func testThreeFileReadUsesActualBOMFormatsAndRetainsSourceBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBlameFormats-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["base", "mine", "theirs"].map { root.appendingPathComponent($0) }
        let texts = ["b", "m", "t"].map { String(repeating: $0, count: 66) + "same\n" }
        for (file, text) in zip(files, texts) { try ComparisonTextEncoding.utf8BOM.encode(text).write(to: file) }
        let working = try WorkingTextMerge(base: files[0], theirs: files[2], mine: files[1])
        let document = try await working.read(engine: engine)
        XCTAssertFalse(MergeText.hasMarkers(document.generatedResult))
        XCTAssertEqual(document.base, texts[0]); XCTAssertEqual(document.mine, texts[1]); XCTAssertEqual(document.theirs, texts[2])
        XCTAssertEqual(document.baseEncoding, .utf8BOM); XCTAssertEqual(document.mineEncoding, .utf8BOM)
        XCTAssertEqual(document.theirsEncoding, .utf8BOM)
        for (file, text) in zip(files, texts) { XCTAssertEqual(try Data(contentsOf: file), try ComparisonTextEncoding.utf8BOM.encode(text)) }
        // Replacing the same files with plain UTF-8 changes conversion behavior;
        // a previous document's BOM mask must not leak into a fresh read.
        for (file, text) in zip(files, texts) { try Data(text.utf8).write(to: file) }
        let plain = try await working.read(engine: engine)
        XCTAssertTrue(MergeText.hasMarkers(plain.generatedResult))
        XCTAssertEqual(plain.base, texts[0]); XCTAssertEqual(plain.mine, texts[1])
    }
    func testReplacedSourcesUseNewEncodingInsteadOfPriorBlameMask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBlameRebind-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["base", "mine", "theirs", "new-mine", "new-theirs"].map { root.appendingPathComponent($0) }
        let base = String(repeating: "b", count: 66) + "same\n"
        let mine = String(repeating: "m", count: 66) + "same\n"
        let theirs = String(repeating: "t", count: 66) + "same\n"
        for (file, text) in zip(files.prefix(3), [base, mine, theirs]) { try ComparisonTextEncoding.utf8BOM.encode(text).write(to: file) }
        try Data(mine.utf8).write(to: files[3]); try Data(theirs.utf8).write(to: files[4])
        let working = try WorkingTextMerge(base: files[0], theirs: files[2], mine: files[1])
        let document = try await working.read(engine: engine)
        XCTAssertFalse(MergeText.hasMarkers(document.generatedResult))
        let changed = try document.replacingSources(mine: WorkingFileComparison.workingContent(at: files[3]), theirs: WorkingFileComparison.workingContent(at: files[4]), engine: engine)
        XCTAssertTrue(MergeText.hasMarkers(changed.generatedResult))
        XCTAssertEqual(changed.baseEncoding, .utf8BOM); XCTAssertEqual(changed.mineEncoding, .utf8)
        XCTAssertEqual(changed.theirsEncoding, .utf8)
        XCTAssertEqual(changed.mine, mine); XCTAssertEqual(changed.theirs, theirs)
    }
}
