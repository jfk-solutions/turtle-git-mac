import XCTest
@testable import TurtleGitCore

final class MergeRegexFiltersTests: XCTestCase {
    private var parser: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex")
    }
    private func filter(_ regex: String, _ replacement: String = "") -> MergeRegexFilter {
        .init(name: "Fixture", expression: regex, replacement: replacement)
    }
    func testECMAScriptCapturesReplacementAndLineBoundaries() throws {
        XCTAssertEqual(try MergeRegexFilters.transformed(["item:42", "item:81", "other", ""], filter: filter("item:([0-9]+)", "value=$1 $$ $&"), executable: parser),
                       ["value=42 $ item:42", "value=81 $ item:81", "other", ""])
        XCTAssertEqual(try MergeRegexFilters.transformed(["雪🦎 12", "snow 34"], filter: filter("[0-9]+", "n"), executable: parser), ["雪🦎 n", "snow n"])
        XCTAssertEqual(try MergeRegexFilters.transformed(["ab", "ac"], filter: filter("^a", "x\ny"), executable: parser), ["x\nyb", "x\nyc"])
        XCTAssertEqual(try MergeRegexFilters.transformed(["prefix\0suffix"], filter: filter("suffix", "changed"), executable: parser), ["prefix"])
    }
    func testFilteredRowsRetainOriginalBytesNumbersAndUnfilteredChanges() throws {
        let a = "stamp 12\r\nkeep\r\nold\r\n", b = "stamp 81\r\nkeep\r\nnew\r\n"
        let result = try MergeRegexFilters.alignment(base: a, destination: b, filter: filter("[0-9]+"), executable: parser)
        XCTAssertEqual(result.rows[0].base.state, .filtered)
        XCTAssertFalse(result.rows[0].changed)
        XCTAssertEqual(result.rows[0].base.lineNumber, 1)
        XCTAssertEqual(result.rows[0].destination.lineNumber, 1)
        XCTAssertEqual(result.differences, [2..<3])
        XCTAssertEqual(result.rows.compactMap { $0.base.lineNumber == nil ? nil : $0.base.text }.joined(), a)
        XCTAssertEqual(result.rows.compactMap { $0.destination.lineNumber == nil ? nil : $0.destination.text }.joined(), b)
        let edit = try FileComparisonEditing.takingOtherRows(result, rows: 0..<1, targetBase: true)
        XCTAssertEqual(edit.text, "stamp 81\r\nkeep\r\nold\r\n")
        XCTAssertFalse(edit.text.contains("stamp \r\n"))
    }
    func testEndingChangesRemainDifferencesAndInsertionRetainsGaps() throws {
        let ending = try MergeRegexFilters.alignment(base: "value 12\r\n", destination: "value 81\n", filter: filter("[0-9]+"), executable: parser)
        XCTAssertFalse(ending.differences.isEmpty)
        let a = "version 1\nlast", b = "inserted\nversion 2\nlast"
        let insertion = try MergeRegexFilters.alignment(base: a, destination: b, filter: filter("[0-9]+"), executable: parser)
        XCTAssertEqual(insertion.rows.compactMap { $0.base.lineNumber == nil ? nil : $0.base.text }.joined(), a)
        XCTAssertEqual(insertion.rows.compactMap { $0.destination.lineNumber == nil ? nil : $0.destination.text }.joined(), b)
        XCTAssertEqual(insertion.rows[0].base.state, .empty)
        XCTAssertEqual(insertion.rows[1].base.state, .filtered)
    }
    func testInvalidExpressionMissingHelperAndCancellationFailExplicitly() throws {
        XCTAssertThrowsError(try MergeRegexFilters.validate(filter("("), executable: parser))
        // ICU lookbehind must not accidentally become accepted here.
        XCTAssertThrowsError(try MergeRegexFilters.validate(filter("(?<=a)b"), executable: parser))
        XCTAssertThrowsError(try MergeRegexFilters.validate(filter("a"), executable: URL(fileURLWithPath: "/missing/turtlegit-merge-regex")))
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try MergeRegexFilters.transformed(["a"], filter: filter("a"), executable: parser, cancellation: token))
    }
    func testNamedSectionsOverwriteRenameAndPersistPrivately() throws {
        let suite = "TurtleGit.MergeRegex.Core." + UUID().uuidString
        let actual = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { actual.removePersistentDomain(forName: suite) }
        let a = MergeRegexFilter(name: "Version", expression: "[0-9]+", replacement: ""), b = MergeRegexFilter(name: "Date", expression: "date=.*", replacement: "")
        try MergeRegexFilters.save([a, b], defaults: actual)
        XCTAssertEqual(MergeRegexFilters.load(defaults: actual), [a, b])
        let renamed = MergeRegexFilter(name: "DATE", expression: "new", replacement: "$1")
        let values = MergeRegexFilters.updating([a, b], oldName: "version", filter: renamed)
        XCTAssertEqual(values, [renamed])
        XCTAssertEqual(MergeRegexFilters.load(defaults: actual), [a, b])
    }
    func testAllEndingStylesAndInvalidKeyShapePreserveSources() throws {
        for ending in MergeLineEnding.allCases {
            let a = "n 12" + ending.rawValue, b = "n 81" + ending.rawValue
            let value = try MergeRegexFilters.alignment(base: a, destination: b, filter: filter("[0-9]+"), executable: parser)
            XCTAssertTrue(value.differences.isEmpty)
            XCTAssertEqual(value.rows.map(\.base.text).joined(), a)
            XCTAssertEqual(value.rows.map(\.destination.text).joined(), b)
        }
        let fallback = FileComparisonAlignment(base: "old\n", destination: "new\n", baseKeys: [], destinationKeys: [])
        XCTAssertFalse(fallback.differences.isEmpty)
    }
}
