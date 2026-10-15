import XCTest
@testable import TurtleGitCore

final class MergeMarkedWordTests: XCTestCase {
    func testSourceCharacterPriorityAndPunctuationRuns() {
        XCTAssertEqual(MergeMarkedWord.selection(at: 3, in: "foo...bar"), NSRange(location: 0, length: 3))
        XCTAssertEqual(MergeMarkedWord.selection(at: 4, in: "foo...bar"), NSRange(location: 3, length: 3))
        XCTAssertEqual(MergeMarkedWord.selection(at: 6, in: "foo...bar"), NSRange(location: 6, length: 3))
        XCTAssertEqual(MergeMarkedWord.selection(at: 4, in: "foo bar"), NSRange(location: 4, length: 3))
        XCTAssertEqual(MergeMarkedWord.selection(at: 7, in: "foo bar"), NSRange(location: 4, length: 3))
        XCTAssertNil(MergeMarkedWord.selection(at: 0, in: "")); XCTAssertNil(MergeMarkedWord.selection(at: -1, in: "foo"))
        XCTAssertEqual(MergeMarkedWord.selection(at: 4, in: "foo_bar"), NSRange(location: 0, length: 7))
        XCTAssertEqual(MergeMarkedWord.selection(at: 4, in: "foo_bar", wordSeparators: "_"), NSRange(location: 4, length: 3))
    }
    func testExactCaseGroupBoundariesAndUnicodeUTF16Offsets() {
        let text = "foo FOO foo_bar .foo.\n🦎foo foo雪 foo\n"
        let lines = MergeFindLine.document(text)
        let matches = MergeMarkedWord.matches("foo", in: lines)
        XCTAssertEqual(matches, [NSRange(location: 0, length: 3), NSRange(location: 17, length: 3), NSRange(location: 33, length: 3)])
        XCTAssertEqual(MergeMarkedWord.rows(for: matches, in: lines), [0, 1])
        let punctuation = MergeFindLine.document(". .. ... .\n")
        XCTAssertEqual(MergeMarkedWord.matches("..", in: punctuation), [NSRange(location: 2, length: 2)])
        XCTAssertEqual(MergeMarkedWord.matches("foo", in: [.init(text: "foo", offset: 5, state: .empty)]), [])
        XCTAssertEqual(MergeMarkedWord.matches("foo", in: [.init(text: "foo", offset: 5, state: .filtered)]), [NSRange(location: 5, length: 3)])
    }
    func testLiteralCustomGroupsAndRowDeduplication() {
        let lines = MergeFindLine.document("foo foo\r\nfoo/foo\nfoo_bar\n")
        let matches = MergeMarkedWord.matches("foo", in: lines, wordSeparators: "/_")
        XCTAssertEqual(MergeMarkedWord.rows(for: matches, in: lines), [0, 1, 2])
        XCTAssertEqual(matches.count, 5)
        XCTAssertEqual(MergeMarkedWord.matches("", in: lines), [])
        XCTAssertEqual(MergeMarkedWord.rows(for: [], in: lines), [])
    }
}
