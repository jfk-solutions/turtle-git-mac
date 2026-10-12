import XCTest
@testable import TurtleGitCore

final class MergeCommentProfilesTests: XCTestCase {
    private let c = MergeCommentTokens(line: "//", blockStart: "/*", blockEnd: "*/")
    func testCustomFileReplacesProfilesAndPreservesLiteralTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ignorecomments.txt")
        let original = try MergeCommentProfileFile.text(at: file)
        XCTAssertEqual(original, MergeCommentProfiles.bundledText())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let custom = "swift=//,/*,*/\nsql=-- ,/*,*/\nplain=,,\n"
        try MergeCommentProfileFile.save(custom, at: file, expected: original)
        XCTAssertEqual(try Data(contentsOf: file), Data(custom.utf8))
        let profiles = try MergeCommentProfileFile.load(at: file)
        XCTAssertEqual(profiles.tokens(fileExtension: "swift"), c)
        XCTAssertEqual(profiles.tokens(fileExtension: "sql")?.line, "-- ")
        XCTAssertNil(profiles.tokens(fileExtension: "cpp"))
        XCTAssertEqual(profiles.tokens(fileExtension: "plain"), .init(line: "", blockStart: "", blockEnd: ""))
        try MergeCommentProfileFile.save(original, at: file, expected: custom)
        XCTAssertEqual(try MergeCommentProfileFile.load(at: file).tokens(fileExtension: "cpp"), c)
    }
    func testMalformedOversizeAndChangedProfilesCannotOverwriteFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ignorecomments.txt")
        let original = try MergeCommentProfileFile.text(at: file)
        let current = "swift=//,/*,*/"
        try MergeCommentProfileFile.save(current, at: file, expected: original)
        for bad in ["swift=//,/*,", "swift=//", "=//,,", "swift=//,,\0", String(repeating: "x", count: MergeCommentProfileFile.maximumBytes + 1)] {
            XCTAssertThrowsError(try MergeCommentProfileFile.save(bad, at: file, expected: current))
            XCTAssertEqual(try MergeCommentProfileFile.text(at: file), current)
        }
        XCTAssertThrowsError(try MergeCommentProfileFile.save("sql=-- ,,", at: file, expected: original))
        XCTAssertEqual(try MergeCommentProfileFile.text(at: file), current)
        // Invalid external edits remain readable in Settings so they can be repaired.
        try Data("swift=//,/*,".utf8).write(to: file)
        XCTAssertEqual(try MergeCommentProfileFile.text(at: file), "swift=//,/*,")
        XCTAssertThrowsError(try MergeCommentProfileFile.load(at: file))
        try MergeCommentProfileFile.save(current, at: file, expected: "swift=//,/*,")
        try Data([0xff]).write(to: file)
        XCTAssertThrowsError(try MergeCommentProfileFile.load(at: file))
        try Data(repeating: 65, count: MergeCommentProfileFile.maximumBytes + 1).write(to: file)
        XCTAssertThrowsError(try MergeCommentProfileFile.load(at: file))
    }
    func testPinnedProfilesAndSourceExtensionPrecedence() throws {
        let profiles = MergeCommentProfiles.bundled()
        XCTAssertEqual(profiles.tokens(fileExtension: "CPP"), c)
        XCTAssertEqual(profiles.tokens(fileExtension: "xml"), .init(line: "", blockStart: "<!--", blockEnd: "-->"))
        XCTAssertEqual(profiles.tokens(fileExtension: "sql")?.line, "-- ")
        XCTAssertEqual(profiles.tokens(paths: ["base.cpp", "mine.py", "theirs.xml"]), c)
        XCTAssertEqual(profiles.tokens(paths: ["base.unknown", "mine.py", "theirs.cpp"])?.line, "#")
        XCTAssertNil(profiles.tokens(paths: ["a.unknown", "b.swift"]))
    }
    func testLineBlockMultilineAndIndependentSourceState() throws {
        XCTAssertEqual(try MergeCommentStripping.strip(["a // comment", "b /* c */ d", "/* start", "body", "*/ end"], tokens: c), ["a ", "b  d", "", "", " end"])
        XCTAssertEqual(try MergeCommentStripping.strip(["/* open", "rest"], tokens: c), ["", ""])
        XCTAssertEqual(try MergeCommentStripping.strip(["fresh // comment"], tokens: c), ["fresh "])
    }
    func testOriginalQuoteHeuristicAndUnicodeAreRetained() throws {
        // Source deliberately stops after finding a quoted line marker instead
        // of searching later markers; escaped quotes aren't a language lexer.
        XCTAssertEqual(try MergeCommentStripping.strip(["let url = \"https://host\"; // remains"], tokens: c), ["let url = \"https://host\"; // remains"])
        XCTAssertEqual(try MergeCommentStripping.strip(["雪🦎 // comment"], tokens: c), ["雪🦎 "])
        XCTAssertEqual(try MergeCommentStripping.strip(["\"/* literal */\""], tokens: c), ["\"/* literal */\""])
    }
    func testEmptyTokensSQLSpaceAndPrecancellation() throws {
        XCTAssertEqual(try MergeCommentStripping.strip(["x // same"], tokens: .init(line: "", blockStart: "", blockEnd: "")), ["x // same"])
        let sql = try XCTUnwrap(MergeCommentProfiles.bundled().tokens(fileExtension: "sql"))
        XCTAssertEqual(try MergeCommentStripping.strip(["x--not comment", "x-- comment"], tokens: sql), ["x--not comment", "x"])
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try MergeCommentStripping.strip(["x"], tokens: c, cancellation: token))
    }
    func testRealEngineIgnoresCommentsOnlyInKeysBeforeRegex() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = "value 12; // old\r\n/* base\r\n*/\r\n", mine = "value 81; // new\r\n/* mine\r\n*/\r\n"
        let filter = MergeRegexFilter(name: "Numbers", expression: "[0-9]+", replacement: "")
        let value = try SubversionMergeDiff.plan(base: base, mine: mine, filter: filter,
            executable: root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"), runtimeRoot: root.appendingPathComponent("build/git-runtime/Git"),
            regexExecutable: root.appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex"), options: .init(ignoreComments: true), commentTokens: c)
        XCTAssertEqual(value.segments.map(\.kind), [.common])
        XCTAssertEqual(value.base.joined(), base); XCTAssertEqual(value.mine.joined(), mine)
        let display = try SubversionComparisonPresentation(plan: value).alignment
        XCTAssertTrue(display.differences.isEmpty)
        XCTAssertEqual(display.rows[0].base.state, .filtered)
    }
}
