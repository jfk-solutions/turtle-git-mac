import XCTest
@testable import TurtleGitCore

final class MergeBlameComparisonTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private let prefix = String(repeating: "a", count: 66)
    private func configuration() -> SubversionMergeConfiguration {
        var value = SubversionMergeConfiguration(executable: root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"), runtimeRoot: root.appendingPathComponent("build/git-runtime/Git"), regexExecutable: root.appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex"))
        value.blame = true
        value.blameEncodings = [.utf8BOM, .utf8BOM, .utf8BOM]
        return value
    }
    func testFixedWidthBoundaryAndUTF16InsteadOfCharacters() {
        XCTAssertEqual(MergeBlameComparison.content(""), "")
        XCTAssertEqual(MergeBlameComparison.content(String(repeating: "x", count: 65)), String(repeating: "x", count: 65))
        XCTAssertEqual(MergeBlameComparison.content(prefix), prefix)
        XCTAssertEqual(MergeBlameComparison.content(prefix + "code"), "code")
        XCTAssertEqual(MergeBlameComparison.content(String(repeating: "x", count: 64) + "🐢code"), "code")
        XCTAssertEqual(MergeBlameComparison.content(String(repeating: "é", count: 66) + "code"), "code")
    }
    func testImmediateKeysPreserveAllSupportedEndingsAndEOF() {
        for ending in MergeLineEnding.allCases {
            XCTAssertEqual(MergeBlameComparison.keys(in: prefix + "code" + ending.rawValue), ["code" + ending.rawValue])
        }
        XCTAssertEqual(MergeBlameComparison.keys(in: "short\r\n" + prefix + "code"), ["short\r\n", "code"])
        XCTAssertEqual(MergeBlameComparison.keys(in: ""), [])
    }
    func testSourceConversionGatesAndAsymmetricUnicodeCompanion() throws {
        let line = prefix + "same\n"
        XCTAssertEqual(MergeBlameComparison.conversionMask(texts: [line, line], encodings: [.windows1252, .windows1252]), [false, false])
        XCTAssertEqual(MergeBlameComparison.conversionMask(texts: [line, line], encodings: [.utf8, .utf8]), [false, false])
        XCTAssertEqual(MergeBlameComparison.conversionMask(texts: [line, line], encodings: [.windows1252, .utf8]), [true, false])
        XCTAssertEqual(MergeBlameComparison.conversionMask(texts: [line, line], encodings: [.utf8BOM, .utf8]), [true, false])
        XCTAssertEqual(MergeBlameComparison.conversionMask(texts: [line, line], encodings: [.utf16LE, .windows1252]), [true, true])
        XCTAssertEqual(MergeBlameComparison.conversionMask(texts: [line, line], encodings: [.utf8, .utf8], forceConversion: true), [true, true])
        for ending in ["\r\n", "\u{000c}", "\u{000b}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(MergeBlameComparison.conversionMask(texts: [prefix + "same" + ending], encodings: [.utf8]), [true])
        }
        XCTAssertEqual(MergeBlameComparison.conversionMask(texts: [line, prefix + "same\n\r"], encodings: [.utf8, .utf8]), [false, false])
        var plain = configuration(); plain.blameEncodings = [.utf8, .utf8]
        XCTAssertEqual(try plain.plan(base: line, mine: String(repeating: "b", count: 66) + "same\n").segments.map(\.kind), [.modified])
        plain.options.ignoreCase = true
        XCTAssertEqual(try plain.plan(base: line, mine: String(repeating: "b", count: 66) + "same\n").segments.map(\.kind), [.common])
    }
    func testTwoFileMetadataOnlyChangesAreCommonAndDisplayOriginals() throws {
        let base = prefix + "same\n", mine = String(repeating: "b", count: 66) + "same\n"
        let value = try configuration().plan(base: base, mine: mine)
        XCTAssertEqual(value.segments.map(\.kind), [.common])
        XCTAssertTrue(value.normalizedComparison)
        XCTAssertFalse(value.contentFiltered)
        XCTAssertEqual(value.base.joined(), base)
        XCTAssertEqual(value.mine.joined(), mine)
        let alignment = try SubversionComparisonPresentation(plan: value).alignment
        XCTAssertTrue(alignment.differences.isEmpty)
        XCTAssertEqual(alignment.rows[0].base.text, base)
        XCTAssertEqual(alignment.rows[0].destination.text, mine)
        XCTAssertEqual(alignment.rows[0].base.lineNumber, 1)
        XCTAssertEqual(alignment.rows[0].destination.lineNumber, 1)
        XCTAssertEqual(alignment.rows[0].base.state, .normal)
        var plain = configuration(); plain.blame = false
        XCTAssertEqual(try plain.plan(base: base, mine: mine).segments.map(\.kind), [.modified])
    }
    func testRealCodeChangesAndShortLinesRemainDifferences() throws {
        XCTAssertEqual(try configuration().plan(base: prefix + "before\n", mine: prefix + "after\n").segments.map(\.kind), [.modified])
        XCTAssertEqual(try configuration().plan(base: "short before\n", mine: "short after\n").segments.map(\.kind), [.modified])
        XCTAssertEqual(try configuration().plan(base: prefix, mine: String(repeating: "b", count: 66)).segments.map(\.kind), [.modified])
    }
    func testThreeWayMetadataDoesNotManufactureConflicts() throws {
        let base = prefix + "same\n", mine = String(repeating: "m", count: 66) + "same\n", theirs = String(repeating: "t", count: 66) + "same\n"
        let value = try configuration().plan(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(value.segments.map(\.kind), [.common])
        XCTAssertFalse(value.hasConflicts)
        XCTAssertEqual(value.theirs?.joined(), theirs)
        XCTAssertEqual(value.base.joined(), base)
        XCTAssertEqual(value.mine.joined(), mine)
    }
    func testBlameRunsAfterCommentAndRegexTransformsBeforeCaseAndWhitespace() throws {
        var options = configuration()
        options.options = .init(whitespace: .ignoreAll, ignoreCase: true, ignoreEndings: true, ignoreComments: true)
        options.commentTokens = .init(line: "//", blockStart: "/*", blockEnd: "*/")
        options.filter = .init(name: "Drop markers", expression: "MARK", replacement: "")
        // Existing source transforms compose without replacing displayed rows.
        let base = prefix + "/*comment*/MARKxSAME  \n"
        let mine = prefix + "/*other*/MARKxs a m e // ignored\r\n"
        let value = try options.plan(base: base, mine: mine)
        XCTAssertEqual(value.segments.map(\.kind), [.common])
        XCTAssertEqual(value.base.joined(), base)
        XCTAssertEqual(value.mine.joined(), mine)
        // A marker inside the 66-unit prefix changes where the cutoff lands.
        options.options = .exact
        options.commentTokens = nil
        XCTAssertEqual(try options.plan(base: "MARK" + String(repeating: "a", count: 66) + "same\n", mine: String(repeating: "b", count: 66) + "same\n").segments.map(\.kind), [.common])
    }
    func testCancellationBeforeBlamePlanDoesNotLaunchHelper() {
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try configuration().plan(base: prefix + "same", mine: prefix + "same", cancellation: token))
    }
}
