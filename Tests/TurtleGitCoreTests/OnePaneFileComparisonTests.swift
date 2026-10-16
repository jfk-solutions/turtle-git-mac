import XCTest
@testable import TurtleGitCore

final class OnePaneFileComparisonTests: XCTestCase {
    private func alignment(_ base:String,_ mine:String,options:MergeComparisonOptions,filter:MergeRegexFilter? = nil) throws -> FileComparisonAlignment {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var engine = SubversionMergeConfiguration(executable:root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"),runtimeRoot:root.appendingPathComponent("build/git-runtime/Git"),regexExecutable:root.appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex"),filter:filter)
        engine.options = options
        return try SubversionComparisonPresentation(plan:engine.plan(base:base,mine:mine)).alignment
    }
    func testWhitespaceCommonRowsUseSourceStatesVisibilityNumbersAndFindCategories() throws {
        let options = MergeComparisonOptions(whitespace:.ignoreChanges)
        let input = try alignment("a  b\r\n","a b\r\n",options:options)
        XCTAssertTrue(input.rows.dropLast().allSatisfy{$0.base.state == .normal && $0.base.hiddenByComparison && $0.destination.hiddenByComparison})
        XCTAssertEqual(input.rows.last?.base.text, ""); XCTAssertEqual(input.rows.last?.base.lineNumber, 2)
        XCTAssertEqual(input.rows.last?.base.hiddenByComparison, false)
        let combined = OnePaneFileComparison(alignment:input,options:options)
        XCTAssertEqual(combined.cells.map(\.state),[.removedWhitespace,.addedWhitespace])
        XCTAssertEqual(combined.cells.map(\.lineNumber),[1,1]);XCTAssertTrue(combined.cells.allSatisfy(\.hiddenByComparison))
        XCTAssertEqual(MergeFind.matches("a",in:MergeFindLine.displayCells(combined.cells),options:.init(modifiedOnly:true)).count,2)
        XCTAssertTrue(MergeLineStatistics(states:combined.cells.map(\.state)).isEmpty)
        XCTAssertTrue(combined.differences.isEmpty)
        XCTAssertEqual(combined.sourceSaveText,"a  b\r\na b\r\n")
        XCTAssertEqual(try combined.editingSource(for:[]).text,combined.sourceSaveText)
    }
    func testSourceLeadingTrimAndAllWhitespaceCollapsePreserveOriginalMine() throws {
        for (base,mine) in [("  a b\n","\ta b\n"),(" \u{301}a\n","\t\u{301}a\n")] {
            let options = MergeComparisonOptions(whitespace:.ignoreChanges)
            let combined = OnePaneFileComparison(alignment:try alignment(base,mine,options:options),options:options)
            XCTAssertEqual(combined.cells.map(\.text),[mine]);XCTAssertEqual(combined.cells.map(\.state),[.normal])
        }
        let options = MergeComparisonOptions(whitespace:.ignoreAll)
        let combined = OnePaneFileComparison(alignment:try alignment("a  b\r\n","ab\r\n",options:options),options:options)
        XCTAssertEqual(combined.cells.map(\.text),["ab\r\n"])
    }
    func testTextFilterAndEndingOnlyCommonRowsHaveIndependentFoldMetadata() throws {
        let filter = MergeRegexFilter(name:"Version",expression:"[0-9]+",replacement:"")
        let input = try alignment("v1\r\n","v2\r\n",options:.exact,filter:filter)
        XCTAssertEqual(input.rows[0].base.state,.filtered);XCTAssertFalse(input.rows[0].base.hiddenByComparison)
        let combined = OnePaneFileComparison(alignment:input,options:.exact)
        XCTAssertEqual(combined.cells.map(\.state),[.removedWhitespace,.addedWhitespace]);XCTAssertFalse(combined.cells.contains(where: \.hiddenByComparison))
        let ignored = MergeComparisonOptions(whitespace:.ignoreAll)
        let all = OnePaneFileComparison(alignment:try alignment("v1\r\n","v2\r\n",options:ignored,filter:filter),options:ignored)
        XCTAssertEqual(all.cells.map(\.text),["v2\r\n"])
        let endings = try alignment("v1\r\n","v1\n",options:.init(),filter:filter)
        XCTAssertEqual(endings.rows[0].base.state,.normal);XCTAssertTrue(endings.rows[0].base.hiddenByComparison)
    }
    func testWhitespaceAliasesKeepSourceDefaultsWhenNormalColorsAreCustomized() {
        var palette = MergeColorPreferences();palette.light[.normal] = .init(0x123456,0x234567);palette.dark[.normal] = .init(0x345678,0x456789)
        for state in [MergeSourceState.removedWhitespace,.addedWhitespace] {
            for dark in [false,true] { XCTAssertEqual(palette.stateColors(state,dark:dark,applied:true),MergeColorPreferences.standard(.normal,dark:dark)) }
            XCTAssertFalse(state.isRemoval);XCTAssertFalse(state.isAddition);XCTAssertFalse(state.isUnchanged)
        }
    }
    func testNeutralAliasSaveAsAndEditingRetainSourcePayloadsWithoutSavingRealRemovals() throws {
        let filter = MergeRegexFilter(name:"Version",expression:"[0-9]+",replacement:"")
        let combined = OnePaneFileComparison(alignment:try alignment("v1\r\nold\r\nend","v2\r\nnew\r\nend",options:.exact,filter:filter),options:.exact)
        XCTAssertEqual(combined.sourceSaveText,"v1\r\nv2\r\nnew\r\nend")
        let display = combined.cells.map{$0.displayText + "\n"}.joined()
        let edit = try combined.applying("edited",ranges:[(display as NSString).range(of:"new")])
        XCTAssertEqual(edit.text,"v1\r\nv2\r\nedited\r\nend")
        let eof = OnePaneFileComparison(alignment:try alignment("v1","v2",options:.exact,filter:filter),options:.exact)
        XCTAssertEqual(eof.sourceSaveText,"v1v2")
    }
    func testDisplayedWhitespaceLineNumbersDoNotShiftOriginalMineCoordinates() throws {
        let filter = MergeRegexFilter(name:"Versions",expression:"[0-9]+",replacement:"")
        let mine = "head\r\nv2\r\nmiddle\r\nnew\r\nlast"
        let combined = OnePaneFileComparison(alignment:try alignment("head\r\nv1\r\nmiddle\r\nold\r\nlast",mine,options:.exact,filter:filter),options:.exact)
        let display = combined.cells.map{$0.displayText + "\n"}.joined(), selected = (display as NSString).range(of:"new")
        let source = try FileComparisonEditing.sourceRange(selected,cells:combined.cells)
        XCTAssertEqual(source,(mine as NSString).range(of:"new"))
        XCTAssertEqual(FileComparisonEditing.displayOffset(sourceOffset:source.location,cells:combined.cells),selected.location)
        XCTAssertEqual(try FileComparisonEditing.selectedText(selected,cells:combined.cells),"new")
        XCTAssertEqual(combined.cells[1].lineNumber,2);XCTAssertFalse(combined.cells[1].hasSourceCoordinate)
    }
    func testRemovedRegionPrecedesAllAdditionsAndReconstructsMine() {
        let old = "same\r\nold one\r\nold two\r\nlast", new = "same\r\nnew one\r\nnew two\r\nlast"
        let alignment = FileComparisonAlignment(base: old, destination: new), projection = OnePaneFileComparison(alignment: alignment)
        XCTAssertEqual(projection.cells.map(\.displayText), ["same", "old one", "old two", "new one", "new two", "last"])
        XCTAssertEqual(projection.rows.filter { !$0.base }.map { $0.cell.text }.joined(), new)
        XCTAssertEqual(projection.differences, [1..<5]); XCTAssertEqual(projection.rows.map(\.alignmentRow), [0,1,2,1,2,3])
    }
    func testEditRemovedPayloadIncludesEditedLineButLeavesOtherRemovalsOut() throws {
        let projection = OnePaneFileComparison(alignment: FileComparisonAlignment(base: "same\r\nold 🦎 words\r\nremove me\r\nlast", destination: "same\r\nnew words\r\nlast"))
        let display = projection.cells.map(\.displayText).joined(separator: "\n") + "\n"
        let edit = try projection.applying("changed", ranges: [(display as NSString).range(of: "old")])
        XCTAssertEqual(edit.text, "same\r\nchanged 🦎 words\r\nnew words\r\nlast")
        XCTAssertFalse(edit.text.contains("remove me"))
        let copy = try MergeSourceComparison.clipboardText(NSRange(location: 5, length: "old 🦎 words".utf16.count), cells: projection.cells)
        XCTAssertEqual(copy, "old 🦎 words")
    }
    func testReplaceMultipleMatchesRetainsOriginalCRLFAndNoFinalTerminator() throws {
        let projection = OnePaneFileComparison(alignment: FileComparisonAlignment(base: "needle old\r\nlast", destination: "needle new\r\nlast"))
        let matches = MergeFind.matches("needle", in: MergeFindLine.displayCells(projection.cells), options: .init())
        XCTAssertEqual(matches.count, 2)
        let edit = try projection.applying("雪", ranges: matches)
        XCTAssertEqual(edit.text, "雪 old\r\n雪 new\r\nlast")
        XCTAssertFalse(MergeLineEndings.hasFinalEnding(edit.text))
        XCTAssertThrowsError(try projection.applying("x", ranges: [NSRange(location: Int.max, length: 1)]))
        XCTAssertThrowsError(try projection.applying("x", ranges: [NSRange(location: Int.max, length: 1), NSRange(location: 0, length: 1)]))
    }
    func testFilteredCasePairsAndWhitespaceCollapse() {
        let old = "same\nUPPER\nlast", new = "same\nlower\nlast"
        let alignment = FileComparisonAlignment(base: old, destination: new, baseKeys: ["same", "key", "last"], destinationKeys: ["same", "key", "last"])
        XCTAssertEqual(OnePaneFileComparison(alignment: alignment).cells.map(\.displayText), ["same", "UPPER", "lower", "last"])
        let spaces = FileComparisonAlignment(base: "a  b\n", destination: "a b\n", baseKeys: ["key"], destinationKeys: ["key"])
        XCTAssertEqual(OnePaneFileComparison(alignment: spaces, options: .init(whitespace: .ignoreChanges)).cells.map(\.displayText), ["a  b","a b"])
    }
}
