import XCTest
@testable import TurtleGitCore

final class HistoryHighlightTests: XCTestCase {
    private var parser: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex") }
    func testPositiveTermsOverlapAdjacencyAndUTF16Offsets() throws {
        for (query, text, expected) in [
            ("ana", "banana", [NSRange(location: 1, length: 5)]),
            ("foo bar", "foobar foo", [NSRange(location: 0, length: 6), NSRange(location: 7, length: 3)]),
            ("-foo +bar", "foo bar", [NSRange(location: 4, length: 3)]),
            ("!foo", "foo foo", [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)]),
            ("\"two words\"", "🦎 two words", [NSRange(location: 3, length: 9)]),
            ("-foo", "foo", []), ("", "foo", []), ("FOO", "foo", [NSRange(location: 0, length: 3)])
        ] {
            XCTAssertEqual(try HistoryHighlighting.ranges([text], query: query, regex: false, caseSensitive: false), [expected], query)
        }
        XCTAssertEqual(try HistoryHighlighting.ranges(["foo FOO"], query: "FOO", regex: false, caseSensitive: true), [[NSRange(location: 4, length: 3)]])
    }
    func testECMAScriptWholeMatchesZeroLengthAndInactivePatterns() throws {
        let texts = ["FOO bar foo", "雪 🦎", "", "before\0after"]
        XCTAssertEqual(try HistoryHighlighting.ranges(texts, query: "!foo|bar", regex: true, caseSensitive: false, executable: parser), [[NSRange(location: 0, length: 3), NSRange(location: 4, length: 3), NSRange(location: 8, length: 3)], [], [], []])
        XCTAssertEqual(try HistoryHighlighting.ranges(["雪 🦎"], query: "\\uD83E\\uDD8E", regex: true, caseSensitive: true, executable: parser), [[NSRange(location: 2, length: 2)]])
        XCTAssertEqual(try HistoryHighlighting.ranges(["a"], query: "^|$", regex: true, caseSensitive: true, executable: parser), [[NSRange(location: 0, length: 0), NSRange(location: 1, length: 0)]])
        XCTAssertEqual(try HistoryHighlighting.ranges(texts, query: "(?<=foo)bar", regex: true, caseSensitive: true, executable: parser), Array(repeating: [], count: texts.count))
        let stopped = OperationCancellation(); stopped.cancel()
        XCTAssertThrowsError(try HistoryHighlighting.ranges(texts, query: "foo", regex: false, caseSensitive: true, cancellation: stopped))
        XCTAssertThrowsError(try HistoryHighlighting.ranges(texts, query: "foo", regex: true, caseSensitive: true, executable: parser, cancellation: stopped))
    }
}
