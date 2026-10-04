import XCTest
@testable import TurtleGitCore

final class MergeSourceComparisonTests: XCTestCase {
    func testRemovedRowsUnequalConflictSidesGapsAndOriginalNumbers() {
        let view = MergeSourceComparison(base: "head\nold1\nold2\ntail\n", mine: "head\nmine1\nmine2\nmine3\ntail\n", theirs: "head\ntheirs1\ntail\n")
        XCTAssertEqual(view.rows.map(\.mine.state), [.normal, .removed, .removed, .conflicted, .conflicted, .conflicted, .normal])
        XCTAssertEqual(view.rows.map(\.theirs.state), [.normal, .removed, .removed, .conflicted, .conflicted, .conflicted, .normal])
        XCTAssertEqual(view.rows.map(\.mine.lineNumber), [1, nil, nil, 2, 3, 4, 5])
        XCTAssertEqual(view.rows.map(\.theirs.lineNumber), [1, nil, nil, 2, nil, nil, 3])
        XCTAssertEqual(view.rows[1].mine.displayText, "old1")
    }
    func testIndependentChangesAndIdenticalAdditions() {
        let view = MergeSourceComparison(base: "first\nsecond\n", mine: "mine\nsecond\nend\n", theirs: "first\ntheirs\nend\n")
        XCTAssertEqual(view.rows.map(\.mine.state), [.removed, .added, .normal, .empty, .added])
        XCTAssertEqual(view.rows.map(\.theirs.state), [.normal, .empty, .removed, .added, .added])
        let identical = MergeSourceComparison(base: "old\n", mine: "same\n", theirs: "same\n")
        XCTAssertEqual(identical.rows.map(\.mine.state), [.removed, .added])
        XCTAssertEqual(identical.rows.map(\.theirs.state), [.removed, .added])
    }
    func testEverySmallRepeatedLineCombinationRecoversBothOriginalFiles() {
        var files = [""]
        for length in 1...3 {
            for bits in 0..<(1 << length) {
                files.append((0..<length).map { bits & (1 << $0) == 0 ? "a\n" : "b\n" }.joined())
            }
        }
        for base in files { for mine in files { for theirs in files {
            let rows = MergeSourceComparison(base: base, mine: mine, theirs: theirs).rows
            for (cells, original) in [(rows.map(\.mine), mine), (rows.map(\.theirs), theirs)] {
                let numbered = cells.filter { $0.lineNumber != nil }
                XCTAssertEqual(numbered.map(\.text).joined(), original, "base=\(base.debugDescription) mine=\(mine.debugDescription) theirs=\(theirs.debugDescription)")
                XCTAssertEqual(numbered.compactMap(\.lineNumber), Array(1..<(numbered.count + 1)))
            }
        } } }
    }
    func testUnicodeCrLfNoFinalNewlineAndEmptyBase() {
        let mine = "🦎 雪\r\nfirst\r\nlast", theirs = "🦎 雪\r\nother\r\nlast"
        let rows = MergeSourceComparison(base: "🦎 雪\r\nbase\r\nlast", mine: mine, theirs: theirs).rows
        XCTAssertEqual(rows.filter { $0.mine.lineNumber != nil }.map(\.mine.text).joined(), mine)
        XCTAssertEqual(rows.first?.mine.displayText, "🦎 雪")
        XCTAssertEqual(rows.last?.mine.displayText, "last")
        let added = MergeSourceComparison(base: "", mine: "mine\n", theirs: "theirs\n").rows
        XCTAssertEqual(added.count, 1); XCTAssertEqual(added.first?.mine.state, .conflicted)
        XCTAssertTrue(MergeSourceComparison(base: "", mine: "", theirs: "").rows.isEmpty)
        let unicode = MergeSourceComparison(base: "é\n", mine: "e\u{301}\n", theirs: "é\n")
        XCTAssertEqual(unicode.rows.map(\.mine.state), [.removed, .added])
        XCTAssertEqual(Data(unicode.rows.filter { $0.mine.lineNumber != nil }.map(\.mine.text).joined().utf8), Data("e\u{301}\n".utf8))
    }
    func testLongerOverlappingEditsPreserveByteOrderAndSourceNumbers() {
        var seed: UInt64 = 8217
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) & 0xffff) }
        func file() -> String {
            let values = ["a", "b", "c", "🦎 雪", "é", "e\u{301}"]
            let count = next() % 13
            return (0..<count).map { index in values[next() % values.count] + (index == count - 1 && next() % 2 == 0 ? "" : next() % 2 == 0 ? "\r\n" : "\n") }.joined()
        }
        for _ in 0..<500 {
            let base = file(), mine = file(), theirs = file()
            let rows = MergeSourceComparison(base: base, mine: mine, theirs: theirs).rows
            for (cells, original) in [(rows.map(\.mine), mine), (rows.map(\.theirs), theirs)] {
                let numbered = cells.filter { $0.lineNumber != nil }
                XCTAssertEqual(Data(numbered.map(\.text).joined().utf8), Data(original.utf8))
                XCTAssertEqual(numbered.compactMap(\.lineNumber), Array(1..<(numbered.count + 1)))
            }
        }
    }
}
