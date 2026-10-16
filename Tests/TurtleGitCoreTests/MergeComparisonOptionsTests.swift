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

extension MergeComparisonOptionsTests {
    func testEnginePlanCapturesOptionsForCommonDisplayAndFolding() throws {
        for whitespace in MergeWhitespaceComparison.allCases {
            let options = MergeComparisonOptions(whitespace:whitespace,ignoreCase:true)
            let value = try plan("ALPHA\r\n","alpha\n",options:options)
            XCTAssertEqual(value.options,options)
            let cell = try SubversionComparisonPresentation(plan:value).alignment.rows[0].base
            XCTAssertEqual(cell.state,.filtered);XCTAssertFalse(cell.hiddenByComparison)
        }
        for whitespace in [MergeWhitespaceComparison.ignoreChanges,.ignoreAll] {
            let value = try plan("a  b\r\n","a b\n",options:.init(whitespace:whitespace))
            let cell = try SubversionComparisonPresentation(plan:value).alignment.rows[0].base
            XCTAssertEqual(cell.state,.normal);XCTAssertTrue(cell.hiddenByComparison)
        }
        let endings = try plan("same\r\n","same\n",options:.init())
        let cell = try SubversionComparisonPresentation(plan:endings).alignment.rows[0].base
        XCTAssertEqual(cell.state,.normal);XCTAssertTrue(cell.hiddenByComparison)
    }
    func testAdjacentMoveSegmentsStickBeforePairingAndDoNotLoseSourceCoordinates() throws {
        let segments:[SubversionDiffSegment] = [.init(kind:.modified,base:0..<2,mine:0..<1,theirs:0..<0),.init(kind:.modified,base:2..<3,mine:1..<3,theirs:0..<0)]
        let value = SubversionDiffPlan(segments:segments,base:["old 1\n","old 2\n","old 3\n"],mine:["new 1\n","new 2\n","new 3\n"],theirs:nil)
        let off = try SubversionComparisonPresentation(plan:value).alignment
        let on = try SubversionComparisonPresentation(plan:value,detectMovedBlocks:true).alignment
        XCTAssertEqual(off.differences,[0..<2,2..<4]);XCTAssertEqual(on.differences,[0..<3])
        XCTAssertEqual(on.rows.prefix(3).map(\.base.lineNumber),[1,2,3]);XCTAssertEqual(on.rows.prefix(3).map(\.destination.lineNumber),[1,2,3])
        XCTAssertEqual(on.rows.map(\.base.text).joined(),value.base.joined());XCTAssertEqual(on.rows.map(\.destination.text).joined(),value.mine.joined())
        XCTAssertEqual(OnePaneFileComparison(alignment:on).sourceSaveText,value.mine.joined())
    }
    func testInvalidAndCancelledComparisonPlansRefusePublication() throws {
        let bad = SubversionDiffPlan(segments:[.init(kind:.common,base:0..<2,mine:0..<1,theirs:0..<0)],base:["a\n"],mine:["b\n"],theirs:nil)
        XCTAssertThrowsError(try SubversionComparisonPresentation(plan:bad))
        let value = try plan("old\n","new\n",options:.exact),token = OperationCancellation();token.cancel()
        XCTAssertThrowsError(try SubversionComparisonPresentation(plan:value,cancellation:token))
    }
}
