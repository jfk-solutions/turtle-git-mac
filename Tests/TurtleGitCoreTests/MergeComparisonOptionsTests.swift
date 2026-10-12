import XCTest
@testable import TurtleGitCore

final class MergeComparisonOptionsTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func plan(_ base: String, _ mine: String, options: MergeComparisonOptions) throws -> SubversionDiffPlan {
        try SubversionMergeDiff.plan(base: base, mine: mine, executable: root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"), runtimeRoot: root.appendingPathComponent("build/git-runtime/Git"), options: options)
    }
    func testSourceDefaultsPrivatePersistenceAndInvalidWhitespaceFallback() throws {
        let suite = "TurtleGit.ComparisonOptions." + UUID().uuidString
        let actual = UserDefaults(suiteName: suite)!
        defer { actual.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MergeComparisonOptions.load(from: actual), .init())
        XCTAssertTrue(MergeComparisonOptions.load(from: actual).ignoreEndings)
        let value = MergeComparisonOptions(whitespace: .ignoreAll, ignoreCase: true, ignoreEndings: false)
        value.save(to: actual); XCTAssertEqual(MergeComparisonOptions.load(from: actual), value)
        actual.set(999, forKey: "TurtleGitMerge.IgnoreWS")
        XCTAssertEqual(MergeComparisonOptions.load(from: actual).whitespace, .compare)
    }
    func testWhitespaceRunsRemainDistinctFromMissingWhitespace() throws {
        let changes = MergeComparisonOptions(whitespace: .ignoreChanges, ignoreEndings: false)
        XCTAssertEqual(changes.key(content: " \ta\t  b ", ending: "\n"), " a b \n")
        XCTAssertEqual(try plan("a\t  b\n", "a b\n", options: changes).segments.map(\.kind), [.common])
        XCTAssertEqual(try plan("ab\n", "a b\n", options: changes).segments.map(\.kind), [.modified])
        let all = MergeComparisonOptions(whitespace: .ignoreAll, ignoreEndings: false)
        XCTAssertEqual(try plan("ab\n", " \ta b \n", options: all).segments.map(\.kind), [.common])
        XCTAssertEqual(all.key(content: "a\u{00a0}b", ending: ""), "a\u{00a0}b")
    }
    func testCaseLowercaseDoesNotUseFullFoldingAndKeepsOriginalRows() throws {
        let options = MergeComparisonOptions(ignoreCase: true, ignoreEndings: false)
        let value = try plan("ALPHA Ä\n", "alpha ä\n", options: options)
        XCTAssertEqual(value.segments.map(\.kind), [.common])
        XCTAssertEqual(value.base, ["ALPHA Ä\n"])
        let presentation = try SubversionComparisonPresentation(plan: value)
        XCTAssertEqual(presentation.alignment.rows[0].base.state, .filtered)
        XCTAssertEqual(try plan("straße\n", "STRASSE\n", options: options).segments.map(\.kind), [.modified])
    }
    func testIgnoreEndingsKeepsEOFAndAllOriginalEndingBytes() throws {
        for ending in MergeLineEnding.allCases {
            let value = try plan("same" + ending.rawValue, "same\n", options: .init())
            XCTAssertEqual(value.segments.map(\.kind), [.common])
            XCTAssertEqual(value.base.joined(), "same" + ending.rawValue)
        }
        XCTAssertEqual(try plan("same", "same\n", options: .init()).segments.map(\.kind), [.modified])
        XCTAssertEqual(try plan("same\r\n", "same\n", options: .exact).segments.map(\.kind), [.modified])
    }
    func testCombinedOptionsOnlyChangeKeysAndBlockTransfersRetainOriginals() throws {
        let options = MergeComparisonOptions(whitespace: .ignoreChanges, ignoreCase: true, ignoreEndings: true)
        let value = try plan("ALPHA\t BETA\r\n", "alpha  beta\n", options: options)
        let alignment = try SubversionComparisonPresentation(plan: value).alignment
        XCTAssertTrue(alignment.differences.isEmpty)
        let edit = try FileComparisonEditing.takingOtherRows(alignment, rows: 0..<1, targetBase: true)
        XCTAssertEqual(edit.text, "alpha  beta\r\n")
        XCTAssertEqual(value.base.joined(), "ALPHA\t BETA\r\n")
    }
}
