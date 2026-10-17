import XCTest
@testable import TurtleGitCore

final class MergeWholeSourceFileTests: XCTestCase {
    private func source(_ base: String, _ mine: String, _ theirs: String) throws -> SubversionMergePresentation {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = SubversionMergeConfiguration(executable: root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"), runtimeRoot: root.appendingPathComponent("build/git-runtime/Git"), regexExecutable: root.appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex"))
        return try .init(plan: engine.plan(base: base, mine: mine, theirs: theirs))
    }
    private func presentation(_ value: SubversionMergePresentation) -> MergeResultPresentation {
        .init(text: value.result, states: value.sources.resultLocator!.states, navigationMap: value.sources.navigationMap)
    }
    func testWholeSourceReconstructsUnmappedResultWithSelectedEndingAndEOF() throws {
        let old = try source("head\nold\ntail", "head\r\nmine 🐢\r\nextra\r\ntail", "head\ntheirs\ntail")
        let arbitrary = MergeResultPresentation(text: "manually written\nresult\n", states: [.edited, .edited])
        XCTAssertNil(MergeAlignedResultProjection(comparison: old.sources, presentation: arbitrary))
        for mine in [true, false] {
            let next = MergeAlignedSourceBlockEdit(wholeFileFrom: old.sources, presentation: arbitrary, mine: mine, lineEnding: .cr)
            XCTAssertEqual(next.presentation.text, mine ? "head\rmine 🐢\rextra\rtail" : "head\rtheirs\rtail")
            XCTAssertTrue(next.presentation.conflicts().isEmpty)
            let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison: next.comparison, presentation: next.presentation))
            XCTAssertFalse(projection.cells.contains { $0.state.isConflict })
            XCTAssertEqual(projection.cells.filter { !$0.state.isExcludedFromResult }.map(\.text).joined(), next.presentation.text)
            XCTAssertEqual(next.presentation.sourceChoiceRevision, 1)
            XCTAssertEqual(next.selectedRows, projection.cells.indices)
            XCTAssertEqual(next.comparison.rows.map { $0.mine.text }, old.sources.rows.map { $0.mine.text })
            XCTAssertEqual(next.comparison.rows.map { $0.theirs.text }, old.sources.rows.map { $0.theirs.text })
        }
        XCTAssertEqual(arbitrary.text, "manually written\nresult\n")
    }
    func testWholeSourceAgreesWithAlignedUseBlockOnAllRecords() throws {
        for texts in [("head\nold\ntail\n", "head\nmine1\nmine2\ntail\n", "head\ntheirs\ntail\n"), ("", "", "new 🐢"), ("old\n", "", "new\n")] {
            let value = try source(texts.0, texts.1, texts.2), initial = presentation(value)
            for mine in [true, false] where !value.sources.rows.isEmpty {
                let block = try MergeAlignedSourceBlockEdit(comparison: value.sources, presentation: initial, rows: value.sources.rows.indices, choice: mine ? .mine : .theirs, lineEnding: .crlf)
                let file = MergeAlignedSourceBlockEdit(wholeFileFrom: value.sources, presentation: initial, mine: mine, lineEnding: .crlf)
                XCTAssertEqual(file.presentation, block.presentation)
                XCTAssertEqual(file.comparison.rows.map { $0.mine.text }, block.comparison.rows.map { $0.mine.text })
                XCTAssertEqual(file.comparison.alignedResultRows?.map(\.state), block.comparison.alignedResultRows?.map(\.state))
            }
        }
    }
    func testWholeSourceAfterBothOrderCopyRemovesTheOtherSourcesInsertedRecords() throws {
        let value = try source("head\nold\ntail", "head\nmine1\nmine2\ntail", "head\ntheirs\ntail"), initial = presentation(value)
        let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison: value.sources, presentation: initial))
        let rows = projection.cells.indices.filter { projection.cells[$0].state == .conflicted }
        let selected = try XCTUnwrap(rows.first)..<(try XCTUnwrap(rows.last) + 1)
        for order in [MergeBlockChoice.mineThenTheirs, .theirsThenMine] {
            let copied = try MergeAlignedSourceBlockEdit(comparison: value.sources, presentation: initial, rows: selected, choice: order)
            let scratch = copied.presentation.reconciling("free text without row mapping")
            for mine in [true, false] {
                let next = MergeAlignedSourceBlockEdit(wholeFileFrom: copied.comparison, presentation: scratch, mine: mine, lineEnding: .lf)
                XCTAssertEqual(next.presentation.text, mine ? "head\nmine1\nmine2\ntail" : "head\ntheirs\ntail")
                XCTAssertNotNil(MergeAlignedResultProjection(comparison: next.comparison, presentation: next.presentation))
                XCTAssertEqual(next.presentation.sourceChoiceRevision, copied.presentation.sourceChoiceRevision + 1)
            }
        }
    }
    func testEmptySourcesReplaceArbitraryResultAndRemoveIgnoredConflictMetadata() throws {
        let value = try source("", "", "")
        let old = MergeResultPresentation(text: "x", states: [.conflictedIgnored], ignoredConflicts: [.init(range: NSRange(location: 0, length: 1), mine: "x", base: "y", theirs: "z")])
        let next = MergeAlignedSourceBlockEdit(wholeFileFrom: value.sources, presentation: old, mine: true, lineEnding: .crlf)
        XCTAssertEqual(next.presentation.text, "")
        XCTAssertTrue(next.presentation.ignoredConflicts.isEmpty)
        XCTAssertTrue(next.presentation.conflicts().isEmpty)
        XCTAssertNotNil(MergeAlignedResultProjection(comparison: next.comparison, presentation: next.presentation))
        XCTAssertTrue(next.selectedRows.isEmpty)
    }
}
