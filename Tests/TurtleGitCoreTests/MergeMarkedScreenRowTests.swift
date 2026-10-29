import XCTest
@testable import TurtleGitCore

/// Independent source contract: BaseView::BuildMarkedWordArray (4520–4562)
/// increments once then breaks per GetLineChars(screenRow), while the painting
/// loop at 1787–1810 keeps matching later occurrences. Screen2View construction
/// at 5274–5313 excludes Hidden rows but retains the original Marker row text.
final class MergeMarkedScreenRowTests: XCTestCase {
    func testStatusCountsRowsWhilePaintingKeepsEveryOccurrence() {
        let text = "alpha alpha beta\n\t😀 alpha beta\n"
        let lines = MergeFindLine.document(text)
        XCTAssertEqual(MergeMarkedWord.matches("alpha", in: lines).count, 3)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: lines.map(\.text)), 2)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("beta", fragments: lines.map(\.text)), 2)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: ["alpha alpha alpha"]), 1)
    }

    func testEachWrapFragmentHasItsOwnSourceBoundaryDomain() {
        // A word divided between screen rows is absent from both rows.
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: ["al", "pha"]), 0)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: ["alpha alpha"]), 1)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: ["alpha", " alpha"]), 2)
        // Source evaluates group boundaries on the fragment, not its logical
        // parent: splitting xalpha before alpha makes alpha eligible.
        XCTAssertEqual(MergeMarkedWord.matches("alpha", in: MergeFindLine.document("xalpha")).count, 0)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: ["x", "alpha"]), 1)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: ["alphax"]), 0)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: ["alpha", "x"]), 1)
    }

    func testCallerFoldProjectionRetainsMarkerTextAndOmitsHiddenRows() {
        let shown = "shown alpha", markerOriginal = "alpha alpha", hidden = "alpha"
        // The actual eligible fragment input is the contract: hidden content
        // is not passed; marker content is not replaced by an ellipsis.
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: [shown, markerOriginal]), 2)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: [shown, markerOriginal, hidden]), 3)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: [shown, "…"]), 1)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: ["", shown, "", markerOriginal, ""]), 2)
    }

    func testMixedEndingsTabsAndSurrogatePairsPreserveLiteralGroupSemantics() {
        let lines = MergeFindLine.document("alpha\r\n\talpha\ralpha\n😀 alpha\u{2028}alpha")
        XCTAssertEqual(lines.map(\.text), ["alpha", "\talpha", "alpha", "😀 alpha", "alpha"])
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: lines.map(\.text)), 5)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("😀", fragments: ["😀 😀", "😀alpha", "\t😀\t"]), 2)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: ["😀alpha", "alpha😀", "😀 alpha"]), 1)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("\r", fragments: lines.map(\.text)), 0)
    }

    func testBoundariesAreLiteralCaseSensitiveAndKeepConfiguredCharacterGroups() {
        // Both adjacent punctuation characters share a source group; a match
        // inside that punctuation run is not a complete marked word.
        XCTAssertEqual(MergeMarkedWord.screenRowCount("-", fragments: ["--", " - ", "x-y"]), 2)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: ["Alpha", "xalpha alpha", "alpha_alpha"]), 1)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: ["alpha_alpha"], wordSeparators: "_"), 1)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("", fragments: ["", "alpha"]), 0)
        XCTAssertEqual(MergeMarkedWord.screenRowCount("alpha", fragments: []), 0)
    }
}
