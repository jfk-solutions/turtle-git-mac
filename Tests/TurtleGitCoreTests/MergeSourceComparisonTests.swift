import XCTest
@testable import TurtleGitCore

final class MergeSourceComparisonTests: XCTestCase {
    func testNavigationUsesSourceNumbersAcrossRemovedRowsGapsAndEveryEnding() {
        for ending in MergeLineEnding.allCases {
            let cells: [MergeSourceCell] = [
                .init(text: "雪" + ending.rawValue, lineNumber: 1, state: .normal),
                .init(text: "removed 🦎" + ending.rawValue, lineNumber: nil, state: .removed),
                .init(text: "", lineNumber: nil, state: .empty),
                .init(text: "last 🦎", lineNumber: 2, state: .conflicted),
                .init(text: "", lineNumber: nil, state: .conflicted)]
            XCTAssertEqual(MergeSourceComparison.navigationLimit(cells: cells), 2)
            XCTAssertEqual(MergeSourceComparison.navigationRange(line: 2, cells: cells), NSRange(location: 14, length: 7))
            XCTAssertEqual(MergeSourceComparison.navigationRange(line: 1, cells: cells), NSRange(location: 0, length: 1))
            XCTAssertNil(MergeSourceComparison.navigationRange(line: 0, cells: cells))
            XCTAssertNil(MergeSourceComparison.navigationRange(line: 3, cells: cells))
            let text = "雪" + ending.rawValue + "middle" + ending.rawValue + "last 🦎"
            let ranges = MergeSourceComparison.navigationRanges(text: text)
            XCTAssertEqual(ranges.count, 3)
            XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["雪", "middle", "last 🦎"])
            XCTAssertEqual(MergeSourceComparison.navigationRanges(text: text + ending.rawValue).count, 3)
        }
        XCTAssertNil(MergeSourceComparison.navigationLimit(cells: []))
        XCTAssertNil(MergeSourceComparison.navigationLimit(cells: [.init(text: "only", lineNumber: 1, state: .normal)]))
        XCTAssertTrue(MergeSourceComparison.navigationRanges(text: "").isEmpty)
    }
    func testRemovedRowsUnequalConflictSidesGapsAndOriginalNumbers() {
        let view = MergeSourceComparison(base: "head\nold1\nold2\ntail\n", mine: "head\nmine1\nmine2\nmine3\ntail\n", theirs: "head\ntheirs1\ntail\n")
        XCTAssertEqual(view.rows.map(\.mine.state), [.normal, .removed, .removed, .conflicted, .conflicted, .conflicted, .normal])
        XCTAssertEqual(view.rows.map(\.theirs.state), [.normal, .removed, .removed, .conflicted, .conflicted, .conflicted, .normal])
        XCTAssertEqual(view.rows.map(\.mine.lineNumber), [1, nil, nil, 2, 3, 4, 5])
        XCTAssertEqual(view.rows.map(\.theirs.lineNumber), [1, nil, nil, 2, nil, nil, 3])
        XCTAssertEqual(view.rows[1].mine.displayText, "old1")
    }
    func testEveryEndingAlignsConflictsGapsAndUnterminatedSources() {
        for ending in MergeLineEnding.allCases {
            let eol = ending.rawValue
            let base = ["head", "old", "tail"].joined(separator: eol)
            let mine = ["head", "mine1", "mine2", "tail"].joined(separator: eol)
            let theirs = ["head", "theirs", "tail"].joined(separator: eol)
            let rows = MergeSourceComparison(base: base, mine: mine, theirs: theirs).rows
            XCTAssertEqual(rows.map(\.mine.lineNumber), [1, nil, 2, 3, 4])
            XCTAssertEqual(rows.map(\.theirs.lineNumber), [1, nil, 2, nil, 3])
            XCTAssertEqual(rows.map(\.mine.state), [.normal, .removed, .conflicted, .conflicted, .normal])
            XCTAssertEqual(rows.map(\.mine.displayText), ["head", "old", "mine1", "mine2", "tail"])
            XCTAssertEqual(rows.map(\.theirs.displayText), ["head", "old", "theirs", "", "tail"])
            XCTAssertEqual(Data(rows.filter { $0.mine.lineNumber != nil }.map(\.mine.text).joined().utf8), Data(mine.utf8))
            XCTAssertEqual(Data(rows.filter { $0.theirs.lineNumber != nil }.map(\.theirs.text).joined().utf8), Data(theirs.utf8))
        }
    }
    func testDifferentEndingsInAllThreeSourcesRetainByteOrderAndNumbering() {
        for baseEnding in MergeLineEnding.allCases { for mineEnding in MergeLineEnding.allCases { for theirEnding in MergeLineEnding.allCases {
            let base = ["雪", "old", "tail"].joined(separator: baseEnding.rawValue)
            let mine = ["雪", "🦎", "mine", "tail"].joined(separator: mineEnding.rawValue)
            let theirs = ["雪", "theirs", "tail"].joined(separator: theirEnding.rawValue)
            let rows = MergeSourceComparison(base: base, mine: mine, theirs: theirs).rows
            for (cells, original, count) in [(rows.map(\.mine), mine, 4), (rows.map(\.theirs), theirs, 3)] {
                let numbered = cells.filter { $0.lineNumber != nil }
                XCTAssertEqual(Data(numbered.map(\.text).joined().utf8), Data(original.utf8))
                XCTAssertEqual(numbered.compactMap(\.lineNumber), Array(1...count))
                XCTAssertTrue(numbered.allSatisfy { MergeLineEndings.styles(in: $0.displayText).isEmpty })
            }
        } } }
    }
    func testClipboardIncludesRemovedAndConflictRowsSkipsEmptyAndNormalizesEveryEnding() throws {
        for ending in MergeLineEnding.allCases {
            let cells: [MergeSourceCell] = [
                .init(text: "first 雪" + ending.rawValue, lineNumber: 1, state: .normal),
                .init(text: "old" + ending.rawValue, lineNumber: nil, state: .removed),
                .init(text: "", lineNumber: nil, state: .empty),
                .init(text: "", lineNumber: nil, state: .conflicted),
                .init(text: "🦎 tail", lineNumber: 2, state: .conflicted)]
            let display = cells.map(\.displayText).joined(separator: "\n") + "\n"
            XCTAssertEqual(try MergeSourceComparison.clipboardText(NSRange(location: 0, length: (display as NSString).length), cells: cells), "first 雪\nold\n\n🦎 tail")
            let old = (display as NSString).range(of: "old")
            XCTAssertEqual(try MergeSourceComparison.clipboardText(old, cells: cells), "old")
            XCTAssertEqual(try MergeSourceComparison.clipboardText(NSRange(location: NSMaxRange(old) + 1, length: 1), cells: cells), "")
            let tail = (display as NSString).range(of: "tail")
            XCTAssertEqual(try MergeSourceComparison.clipboardText(tail, cells: cells), "tail")
            XCTAssertEqual(try MergeSourceComparison.clipboardText(NSRange(location: 0, length: 0), cells: cells), "")
            XCTAssertThrowsError(try MergeSourceComparison.clipboardText(NSRange(location: NSNotFound, length: 1), cells: cells))
        }
        XCTAssertEqual(try MergeSourceComparison.clipboardText(NSRange(location: 0, length: 0), cells: []), "")
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
