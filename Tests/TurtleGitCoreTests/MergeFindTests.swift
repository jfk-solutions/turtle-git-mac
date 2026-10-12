import XCTest
@testable import TurtleGitCore

final class MergeFindTests: XCTestCase {
    func testLiteralCaseAndUTF16Ranges() {
        let lines = MergeFindLine.document("🦎 Foo foo.*\r\n雪 FOO\n")
        XCTAssertEqual(MergeFind.matches("foo", in: lines, options: .init()), [.init(location: 3, length: 3), .init(location: 7, length: 3), .init(location: 16, length: 3)])
        XCTAssertEqual(MergeFind.matches("Foo", in: lines, options: .init(matchCase: true)), [.init(location: 3, length: 3)])
        XCTAssertEqual(MergeFind.matches(".*", in: lines, options: .init()), [.init(location: 10, length: 2)])
        XCTAssertTrue(MergeFind.matches("foo.*\r\n雪", in: lines, options: .init()).isEmpty)
    }
    func testWholeWordUsesSourceSeparatorsAndCustomOverrides() {
        let lines = MergeFindLine.document("foo_foo foo-bar (foo) foo雪 foo\tfoo")
        XCTAssertEqual(MergeFind.matches("foo", in: lines, options: .init(wholeWord: true)).count, 4)
        XCTAssertEqual(MergeFind.matches("foo", in: lines, options: .init(wholeWord: true, wordSeparators: "_")).count, 4)
    }
    func testModifiedFilteringExcludesNormalFilteredAndGaps() {
        let states: [MergeSourceState] = [.normal, .filtered, .empty, .added, .removed, .conflicted]
        let lines = states.enumerated().map { MergeFindLine(text: "hit", offset: $0.offset * 4, state: $0.element) }
        XCTAssertEqual(MergeFind.matches("hit", in: lines, options: .init()).count, 5)
        XCTAssertEqual(MergeFind.matches("hit", in: lines, options: .init(modifiedOnly: true)).map(\.location), [12, 16, 20])
    }
    func testNonoverlapAndReplacementDoesNotRescanInsertedNeedle() {
        let matches = MergeFind.matches("aa", in: MergeFindLine.document("aaaaa"), options: .init())
        XCTAssertEqual(matches, [.init(location: 0, length: 2), .init(location: 2, length: 2)])
        let value = NSMutableString(string: "aaaaa")
        for range in matches.reversed() { value.replaceCharacters(in: range, with: "aaa") }
        XCTAssertEqual(value as String, "aaaaaaa")
    }
    func testDirectionWrapAndReplaceCurrentSelection() {
        let matches = [NSRange(location: 2, length: 3), NSRange(location: 9, length: 3)]
        XCTAssertEqual(MergeFind.next(in: matches, selection: matches[0], upwards: false)?.range, matches[1])
        XCTAssertEqual(MergeFind.next(in: matches, selection: matches[1], upwards: false)?.wrapped, true)
        XCTAssertEqual(MergeFind.next(in: matches, selection: matches[0], upwards: true)?.range, matches[1])
        XCTAssertEqual(MergeFind.next(in: matches, selection: matches[1], upwards: true)?.range, matches[0])
        XCTAssertEqual(MergeFind.next(in: matches, selection: matches[0], upwards: false, includeSelection: true)?.range, matches[0])
        XCTAssertEqual(MergeFind.next(in: matches, selection: matches[0], upwards: true, includeSelection: true)?.range, matches[0])
        XCTAssertNil(MergeFind.next(in: [], selection: .init(location: 0, length: 0), upwards: false))
    }
    func testMixedEndingsRetainOriginalOffsetsAndDoNotMatchTerminators() {
        let text = "hit\r\nhit\rhit\nhit\u{2028}hit"
        let lines = MergeFindLine.document(text)
        XCTAssertEqual(MergeFind.matches("hit", in: lines, options: .init()).map(\.location), [0, 5, 9, 13, 17])
        XCTAssertTrue(MergeFind.matches("\r", in: lines, options: .init()).isEmpty)
    }
    func testDisplayCellsOffsetDoesNotBecomeFileOffset() throws {
        let alignment = FileComparisonAlignment(base: "a\nfoo\nz\n", destination: "a\nz\n")
        let cells = alignment.rows.map(\.destination)
        XCTAssertTrue(MergeFind.matches("foo", in: MergeFindLine.displayCells(cells), options: .init()).isEmpty)
        let matches = MergeFind.matches("z", in: MergeFindLine.displayCells(cells), options: .init())
        XCTAssertEqual(try FileComparisonEditing.sourceRange(matches[0], cells: cells), NSRange(location: 2, length: 1))
    }
    func testPreferenceDefaultsAndSessionOnlyDirection() throws {
        let name = "TurtleGit.MergeFind.Core." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(MergeFindOptions.load(from: defaults), .init())
        var value = MergeFindOptions(matchCase: true, modifiedOnly: true, wholeWord: true, searchUp: true)
        value.save(to: defaults); value.searchUp = false
        XCTAssertEqual(MergeFindOptions.load(from: defaults), value)
        XCTAssertEqual(defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("TurtleGitMerge.Find") }.count, 3)
    }
}
