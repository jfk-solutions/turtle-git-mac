import XCTest
@testable import TurtleGitCore

final class SubversionMergePresentationTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func configuration(_ filter: MergeRegexFilter? = nil) -> SubversionMergeConfiguration {
        .init(executable: root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"), runtimeRoot: root.appendingPathComponent("build/git-runtime/Git"),
              regexExecutable: root.appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex"), filter: filter)
    }
    private func presentation(_ base: String, _ mine: String, _ theirs: String, filter: MergeRegexFilter? = nil) throws -> SubversionMergePresentation {
        try .init(plan: configuration(filter).plan(base: base, mine: mine, theirs: theirs))
    }
    private func resultPresentation(_ value:SubversionMergePresentation) -> MergeResultPresentation {
        .init(text:value.result,states:value.sources.resultLocator!.states,ignoredConflicts:value.sources.ignoredConflicts,navigationMap:value.sources.navigationMap)
    }
    func testAlignedEditCommonKeepsRemovedRowsAndExactMarkerBytes() throws {
        let value = try presentation("head\nold1\nold2\ntail\n","head\nmine1\nmine2\ntail\n","head\ntheirs1\ntheirs2\ntail\n")
        let initial = resultPresentation(value)
        let edited = try MergeAlignedResultEdit(comparison:value.sources,presentation:initial,range:NSRange(location:0,length:4),replacement:"HEAD 🐢")
        XCTAssertEqual(edited.presentation.text,"HEAD 🐢" + initial.text.dropFirst(4))
        let projected = try XCTUnwrap(MergeAlignedResultProjection(comparison:edited.comparison,presentation:edited.presentation))
        XCTAssertEqual(projected.cells.map(\.displayText),["HEAD 🐢","old1","old2","","","tail"])
        XCTAssertEqual(projected.cells.map(\.state),[.edited,.identicalRemoved,.identicalRemoved,.conflicted,.conflicted,.normal])
        XCTAssertEqual(edited.comparison.rows.map { $0.mine.text },value.sources.rows.map { $0.mine.text })
        XCTAssertEqual(edited.displayCaret,"HEAD 🐢".utf16.count)
    }
    func testTypingOneConflictSlotRetainsOtherUnresolvedSlot() throws {
        let value = try presentation("head\nold1\nold2\ntail\n","head\nmine1\nmine2\ntail\n","head\ntheirs1\ntheirs2\ntail\n")
        let initial = resultPresentation(value), projection = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:initial))
        let row = try XCTUnwrap(projection.cells.firstIndex { $0.state == .conflicted })
        let edit = try MergeAlignedResultEdit(comparison:value.sources,presentation:initial,range:NSRange(location:projection.displayRanges[row].location,length:0),replacement:"manual 🐢")
        let after = try XCTUnwrap(MergeAlignedResultProjection(comparison:edit.comparison,presentation:edit.presentation))
        XCTAssertEqual(after.cells[row].state,.edited)
        XCTAssertEqual(after.cells[row].displayText,"manual 🐢")
        XCTAssertEqual(after.cells[row + 1].state,.conflicted)
        XCTAssertEqual(edit.presentation.conflicts().count,1)
        XCTAssertEqual(edit.presentation.conflicts()[0].mine,"mine2\n")
        XCTAssertEqual(edit.presentation.conflicts()[0].theirs,"theirs2\n")
        XCTAssertTrue(edit.presentation.text.hasPrefix("head\nmanual 🐢\n<<<<<<< Mine\n"))
        XCTAssertEqual(edit.comparison.rows.map { $0.mine.text },value.sources.rows.map { $0.mine.text })
    }
    func testTypingRemovedRecordRestoresItWithoutSavingOtherRemovedRows() throws {
        let value = try presentation("head\nold\ntail\n","head\nnew\ntail\n","head\nold\ntail\n"), initial = resultPresentation(value)
        let projected = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:initial))
        let row = try XCTUnwrap(projected.cells.firstIndex { $0.state.isRemoval })
        let edit = try MergeAlignedResultEdit(comparison:value.sources,presentation:initial,range:NSRange(location:projected.displayRanges[row].location + 3,length:0),replacement:"!")
        XCTAssertEqual(edit.presentation.text,"head\nold!\nnew\ntail\n")
        XCTAssertEqual(try XCTUnwrap(MergeAlignedResultProjection(comparison:edit.comparison,presentation:edit.presentation)).cells[row].state,.edited)
        XCTAssertEqual(value.result,"head\nnew\ntail\n")
    }
    func testMultilineAlignedPasteAndDeletionKeepAllSourceCoordinates() throws {
        let value = try presentation("a\r\nb\r\nc", "a\r\nb\r\nc", "a\r\nb\r\nc"), initial = resultPresentation(value)
        let paste = try MergeAlignedResultEdit(comparison:value.sources,presentation:initial,range:NSRange(location:1,length:0),replacement:"🐢\nnew\nlast")
        XCTAssertEqual(paste.presentation.text,"a🐢\r\nnew\r\nlast\r\nb\r\nc")
        XCTAssertEqual(paste.comparison.rows.count,5)
        XCTAssertEqual(paste.comparison.rows.map { $0.mine.lineNumber },[1,nil,nil,2,3])
        let projected = try XCTUnwrap(MergeAlignedResultProjection(comparison:paste.comparison,presentation:paste.presentation))
        XCTAssertEqual(projected.cells.map(\.lineNumber),[1,2,3,4,5])
        let start = projected.displayRanges[0].location + 1, end = projected.displayRanges[3].location + 1
        let deletion = try MergeAlignedResultEdit(comparison:paste.comparison,presentation:paste.presentation,range:NSRange(location:start,length:end - start),replacement:"")
        XCTAssertEqual(deletion.presentation.text,"a\r\nc")
        XCTAssertEqual(deletion.comparison.rows.filter { $0.mine.lineNumber != nil }.map { $0.mine.text }.joined(),"a\r\nb\r\nc")
        XCTAssertNotNil(MergeAlignedResultProjection(comparison:deletion.comparison,presentation:deletion.presentation))
    }
    func testFinalEmptyEditedRecordAndEmptyDocumentStayAligned() throws {
        let value = try presentation("a", "a", "a"), initial = resultPresentation(value)
        let edit = try MergeAlignedResultEdit(comparison:value.sources,presentation:initial,range:NSRange(location:1,length:0),replacement:"\n")
        let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison:edit.comparison,presentation:edit.presentation))
        XCTAssertEqual(edit.presentation.text,"a\n")
        XCTAssertEqual(projection.cells.map(\.state),[.edited,.edited])
        XCTAssertEqual(projection.cells.map(\.lineNumber),[1,2])
        XCTAssertEqual(edit.displayCaret,2)
        let empty = try presentation("", "", "")
        let typed = try MergeAlignedResultEdit(comparison:empty.sources,presentation:resultPresentation(empty),range:NSRange(location:0,length:0),replacement:"🐢")
        XCTAssertEqual(typed.presentation.text,"🐢")
        XCTAssertEqual(typed.comparison.rows.count,1)
        XCTAssertNotNil(MergeAlignedResultProjection(comparison:typed.comparison,presentation:typed.presentation))
    }
    func testAlignedDisplayCoordinatesKeepCRLFAndUTF16Separate() throws {
        let value = try presentation("🐢\r\nold\r\ntail", "🐢\r\nnew\r\ntail", "🐢\r\nold\r\ntail")
        let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:resultPresentation(value)))
        XCTAssertEqual(projection.displayText,"🐢\nold\nnew\ntail\n")
        XCTAssertEqual(projection.serializedRange(displayRange:NSRange(location:7,length:3)),NSRange(location:4,length:3))
        XCTAssertEqual(projection.displayRange(serializedRange:NSRange(location:4,length:3)),NSRange(location:7,length:3))
        XCTAssertEqual(projection.serializedRange(displayRange:NSRange(location:3,length:3)),NSRange(location:4,length:0))
    }
    func testBothOrdersExpandAllThreeViewsAndRetainSourceCoordinates() throws {
        let value = try presentation("head\nold\ntail\n","head\nmine1\nmine2\ntail\n","head\ntheirs\ntail\n"), initial = resultPresentation(value)
        let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:initial))
        let first = try XCTUnwrap(projection.cells.firstIndex { $0.state == .conflicted }), rows = first..<(first + 2)
        for choice in [MergeBlockChoice.mineThenTheirs,.theirsThenMine] {
            let edit = try MergeAlignedSourceBlockEdit(comparison:value.sources,presentation:initial,rows:rows,choice:choice)
            let result = try XCTUnwrap(MergeAlignedResultProjection(comparison:edit.comparison,presentation:edit.presentation))
            XCTAssertEqual(result.cells.count,projection.cells.count + 2)
            XCTAssertEqual(edit.selectedRows,first..<(first + 4))
            XCTAssertEqual(edit.presentation.text,choice == .mineThenTheirs ? "head\nmine1\nmine2\ntheirs\ntail\n" : "head\ntheirs\nmine1\nmine2\ntail\n")
            XCTAssertEqual(edit.comparison.rows.filter { $0.mine.hasSourceCoordinate }.map { $0.mine.text }.joined(),"head\nmine1\nmine2\ntail\n")
            XCTAssertEqual(edit.comparison.rows.filter { $0.theirs.hasSourceCoordinate }.map { $0.theirs.text }.joined(),"head\ntheirs\ntail\n")
            let a = edit.comparison.rows[first], b = edit.comparison.rows[first + 2]
            XCTAssertEqual(choice == .mineThenTheirs ? a.mine.state : a.theirs.state,.yoursAdded)
            XCTAssertEqual(choice == .mineThenTheirs ? b.theirs.state : b.mine.state,.theirsAdded)
            XCTAssertTrue(choice == .mineThenTheirs ? a.theirs.state.isViewEmpty : a.mine.state.isViewEmpty)
            XCTAssertEqual(result.cells.filter { $0.state == .resolvedEmpty }.count,1)
            XCTAssertNil(result.cells.first { $0.state == .resolvedEmpty }?.lineNumber)
            XCTAssertTrue(edit.presentation.conflicts().isEmpty)
            // Exact row maps permit a subsequent alternative without replacing
            // the other copy or leaving the aligned editor.
            let again = try MergeAlignedSourceBlockEdit(comparison:edit.comparison,presentation:edit.presentation,rows:first..<(first + 1),choice:choice == .mineThenTheirs ? .theirs : .mine)
            XCTAssertNotNil(MergeAlignedResultProjection(comparison:again.comparison,presentation:again.presentation))
            XCTAssertEqual(again.presentation.text,choice == .mineThenTheirs ? "head\nmine2\ntheirs\ntail\n" : "head\nmine1\nmine2\ntail\n")
        }
    }
    func testSourceChoiceCanResolveOneSlotInsideUnresolvedGroup() throws {
        let value = try presentation("head\nold1\nold2\ntail\n","head\nmine1\nmine2\ntail\n","head\ntheirs1\ntheirs2\ntail\n"), initial = resultPresentation(value)
        let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:initial))
        let row = try XCTUnwrap(projection.cells.firstIndex { $0.state == .conflicted })
        let edit = try MergeAlignedSourceBlockEdit(comparison:value.sources,presentation:initial,rows:row..<(row + 1),choice:.mine)
        XCTAssertTrue(edit.presentation.text.hasPrefix("head\nmine1\n<<<<<<< Mine\n"))
        XCTAssertEqual(edit.presentation.conflicts().first?.mine,"mine2\n")
        XCTAssertEqual(edit.presentation.conflicts().first?.theirs,"theirs2\n")
        let result = try XCTUnwrap(MergeAlignedResultProjection(comparison:edit.comparison,presentation:edit.presentation))
        XCTAssertEqual(result.cells[row].state,.resolved)
        XCTAssertEqual(result.cells[row + 1].state,.conflicted)
    }
    func testResolvedEmptyIsExcludedButRemainsAResolvedViewRecord() throws {
        let value = try presentation("head\nold\ntail\n","head\nmine1\nmine2\ntail\n","head\ntheirs\ntail\n"), initial = resultPresentation(value)
        let row = try XCTUnwrap(value.sources.rows.firstIndex { $0.theirs.state == .conflictEmpty })
        let edit = try MergeAlignedSourceBlockEdit(comparison:value.sources,presentation:initial,rows:row..<(row + 1),choice:.theirs)
        let projected = try XCTUnwrap(MergeAlignedResultProjection(comparison:edit.comparison,presentation:edit.presentation))
        XCTAssertEqual(projected.cells[row].state,.resolvedEmpty)
        XCTAssertNil(projected.cells[row].lineNumber)
        XCTAssertEqual(projected.cells[row].state.colorRole,.resolved)
        XCTAssertFalse(MergeSourceState.resolvedEmpty.isViewEmpty)
        XCTAssertFalse(MergeSourceState.resolvedEmpty.isConflict)
        XCTAssertEqual(projected.serializedRanges[row].length,0)
        XCTAssertFalse(edit.presentation.text.contains("mine2"))
        XCTAssertEqual(edit.presentation.conflicts().first?.mine,"mine1\n")
        XCTAssertEqual(MergeLineStatistics(states:projected.cells.map(\.state)).conflicted,1)
        let typed = try MergeAlignedResultEdit(comparison:edit.comparison,presentation:edit.presentation,range:NSRange(location:projected.displayRanges[row].location,length:0),replacement:"restored")
        XCTAssertEqual(try XCTUnwrap(MergeAlignedResultProjection(comparison:typed.comparison,presentation:typed.presentation)).cells[row].state,.edited)
        XCTAssertTrue(typed.presentation.text.contains("restored\n"))
    }
    func testChoosingAnInsertedSourceGapCleansOnlyAllPaneEmptyRows() throws {
        let value = try presentation("head\ntail\n","head\ntail\n","head\ntail\n"), initial = resultPresentation(value)
        let paste = try MergeAlignedResultEdit(comparison:value.sources,presentation:initial,range:NSRange(location:4,length:0),replacement:"\ninserted")
        XCTAssertEqual(paste.comparison.rows.count,3)
        let restored = try MergeAlignedSourceBlockEdit(comparison:paste.comparison,presentation:paste.presentation,rows:1..<2,choice:.mine)
        XCTAssertEqual(restored.comparison.rows.count,2)
        XCTAssertEqual(restored.presentation.text,value.result)
        XCTAssertEqual(restored.selectedRows,1..<1)
        XCTAssertEqual(restored.comparison.rows.map { $0.mine.lineNumber },[1,2])
        XCTAssertNotNil(MergeAlignedResultProjection(comparison:restored.comparison,presentation:restored.presentation))
        let copy = try MergeAlignedSourceBlockEdit(comparison:value.sources,presentation:initial,rows:0..<1,choice:.mineThenTheirs)
        let gap = try MergeAlignedSourceBlockEdit(comparison:copy.comparison,presentation:copy.presentation,rows:0..<1,choice:.theirs)
        XCTAssertEqual(gap.comparison.rows.count,3,"A real source row must prevent cleanup")
        XCTAssertEqual(gap.presentation.text,value.result)
    }
    func testBothOrdersNormalizeOnlyFirstBlockAndRetainEOF() throws {
        let value = try presentation("old","mine\r\nlast","theirs\nend"), initial = resultPresentation(value)
        let projected = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:initial))
        let first = try XCTUnwrap(projected.cells.firstIndex { $0.state == .conflicted })
        let edit = try MergeAlignedSourceBlockEdit(comparison:value.sources,presentation:initial,rows:first..<projected.cells.count,choice:.mineThenTheirs,lineEnding:.crlf)
        XCTAssertEqual(edit.presentation.text,"mine\r\nlasttheirs\nend")
        XCTAssertNotNil(MergeAlignedResultProjection(comparison:edit.comparison,presentation:edit.presentation))
        XCTAssertEqual(edit.comparison.rows.filter { $0.theirs.hasSourceCoordinate }.map { $0.theirs.text }.joined(),"theirs\nend")
    }
    func testWholeViewWhitespaceTransformsRetainStatesRemovedRowsAndMarkerBytes() throws {
        let value = try presentation("\tkeep  \r\n\told  \r\ntail", "\tkeep  \r\nmine\r\ntail", "\tkeep  \r\ntheirs\r\ntail"), initial = resultPresentation(value)
        let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:initial))
        let oldMarker = (initial.text as NSString).substring(with:initial.conflicts()[0].range)
        let spaces = try MergeAlignedResultTransform(comparison:value.sources,presentation:initial,operation:.whitespace(.tabsToSpaces,tabWidth:4))
        let converted = try XCTUnwrap(MergeAlignedResultProjection(comparison:spaces.comparison,presentation:spaces.presentation))
        XCTAssertEqual(spaces.changedRows,[0,1])
        XCTAssertEqual(converted.cells.map(\.state),projection.cells.map(\.state))
        XCTAssertEqual(converted.cells[0].text,"    keep  \r\n")
        XCTAssertEqual(converted.cells[1].text,"    old  \r\n")
        XCTAssertEqual((spaces.presentation.text as NSString).substring(with:spaces.presentation.conflicts()[0].range),oldMarker)
        XCTAssertFalse(spaces.presentation.text.contains("    old"))
        let trim = try MergeAlignedResultTransform(comparison:spaces.comparison,presentation:spaces.presentation,operation:.whitespace(.trimRight,tabWidth:4))
        let trimmed = try XCTUnwrap(MergeAlignedResultProjection(comparison:trim.comparison,presentation:trim.presentation))
        XCTAssertEqual(trimmed.cells[0].text,"    keep\r\n")
        XCTAssertEqual(trimmed.cells[1].text,"    old\r\n")
        XCTAssertEqual(trimmed.cells.map(\.lineNumber),projection.cells.map(\.lineNumber))
        XCTAssertEqual(trim.comparison.rows.map { $0.mine.text },value.sources.rows.map { $0.mine.text })
        let tabs = try MergeAlignedResultTransform(comparison:trim.comparison,presentation:trim.presentation,operation:.whitespace(.spacesToTabs,tabWidth:4))
        XCTAssertTrue(tabs.presentation.text.hasPrefix("\tkeep\r\n"))
        let noOp = try MergeAlignedResultTransform(comparison:tabs.comparison,presentation:tabs.presentation,operation:.whitespace(.spacesToTabs,tabWidth:4))
        XCTAssertTrue(noOp.changedRows.isEmpty)
        XCTAssertEqual(noOp.presentation,tabs.presentation)
    }
    func testRecordEndingTransformPreservesMarkersNoEndingAndResolutionStates() throws {
        let value = try presentation("head\r\nold\r\ntail", "head\r\nmine\r\ntail", "head\r\ntheirs\r\ntail"), initial = resultPresentation(value)
        let end = try MergeAlignedResultTransform(comparison:value.sources,presentation:initial,operation:.lineEndings(.cr))
        let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison:end.comparison,presentation:end.presentation))
        XCTAssertEqual(end.changedRows,[0,1])
        XCTAssertEqual(projection.cells[0].text,"head\r")
        XCTAssertEqual(projection.cells[1].text,"old\r")
        XCTAssertEqual(projection.cells.last?.text,"tail")
        XCTAssertEqual((end.presentation.text as NSString).substring(with:end.presentation.conflicts()[0].range),(initial.text as NSString).substring(with:initial.conflicts()[0].range))
        let row = try XCTUnwrap(projection.cells.firstIndex { $0.state == .conflicted })
        let resolved = try MergeAlignedSourceBlockEdit(comparison:end.comparison,presentation:end.presentation,rows:row..<(row + 1),choice:.mine,lineEnding:.cr)
        XCTAssertEqual(resolved.presentation.text,"head\rmine\rtail")
        let formatted = try MergeAlignedResultTransform(comparison:resolved.comparison,presentation:resolved.presentation,operation:.lineEndings(.lineSeparator))
        XCTAssertEqual(formatted.presentation.text,"head\u{2028}mine\u{2028}tail")
        XCTAssertEqual(try XCTUnwrap(MergeAlignedResultProjection(comparison:formatted.comparison,presentation:formatted.presentation)).cells[row].state,.resolved)
    }
    func testFormattingIgnoredPayloadRetainsConsistentUnresolvedMetadata() throws {
        var engine = configuration(); engine.options = .init(whitespace:.ignoreAll)
        let value = try SubversionMergePresentation(plan:engine.plan(base:"a b\n",mine:"ab  \n",theirs:"a  b\n")), initial = resultPresentation(value)
        XCTAssertEqual(initial.ignoredConflicts.count,1)
        let formatted = try MergeAlignedResultTransform(comparison:value.sources,presentation:initial,operation:.whitespace(.trimRight,tabWidth:4))
        XCTAssertEqual(formatted.presentation.text,"ab\n")
        XCTAssertEqual(formatted.presentation.ignoredConflicts.first?.mine,"ab\n")
        XCTAssertEqual(formatted.presentation.ignoredConflicts.first?.range,NSRange(location:0,length:3))
        XCTAssertEqual(formatted.presentation.conflicts().first?.isIgnored,true)
        let projected = try XCTUnwrap(MergeAlignedResultProjection(comparison:formatted.comparison,presentation:formatted.presentation))
        XCTAssertEqual(projected.cells.first?.state,.conflictedIgnored)
        XCTAssertEqual(formatted.comparison.rows.first?.mine.text,"ab  \n")
        let resolved = try MergeAlignedSourceBlockEdit(comparison:formatted.comparison,presentation:formatted.presentation,rows:0..<1,choice:.mine)
        XCTAssertEqual(resolved.presentation.text,"ab  \n")
        XCTAssertTrue(resolved.presentation.ignoredConflicts.isEmpty)
    }
    func testExplicitOutputEndingControlsTypingWithOnlyBlankConflictRecords() throws {
        let value = try presentation("old\r\n","mine\r\n","theirs\r\n"), initial = resultPresentation(value)
        let projected = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:initial)), row = projected.cells.firstIndex { $0.state == .conflicted }!
        let edit = try MergeAlignedResultEdit(comparison:value.sources,presentation:initial,range:NSRange(location:projected.displayRanges[row].location,length:0),replacement:"first\nlast",lineEnding:.crlf)
        XCTAssertEqual(edit.presentation.text,"first\r\nlast")
        XCTAssertNotNil(MergeAlignedResultProjection(comparison:edit.comparison,presentation:edit.presentation))
    }
    func testAlignedResultRetainsRemovedRecordsAndLogicalNumbers() throws {
        let value = try presentation("head\nold\ntail\n","head\nold\ntail\n","head\nnew\ntail\n")
        let rows = try XCTUnwrap(value.sources.alignedResultRows)
        XCTAssertEqual(rows.map(\.displayText),["head","old","new","tail"])
        XCTAssertEqual(rows.map(\.state),[.normal,.theirsRemoved,.theirsAdded,.normal])
        XCTAssertEqual(rows.map(\.lineNumber),[1,nil,2,3])
        XCTAssertEqual(rows.count,value.sources.rows.count)
        let result = MergeResultPresentation(text:value.result,states:value.sources.resultLocator!.states,navigationMap:value.sources.navigationMap)
        let projected = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:result))
        XCTAssertEqual(projected.cells.map(\.displayText),rows.map(\.displayText))
        XCTAssertEqual(projected.serializedRanges[1],NSRange(location:5,length:0))
    }
    func testConflictMarkerLinesAreNotAlignedResultRecords() throws {
        let value = try presentation("head\nold1\nold2\ntail\n","head\nmine1\nmine2\ntail\n","head\ntheirs1\ntheirs2\ntail\n")
        let initial = try XCTUnwrap(value.sources.alignedResultRows)
        XCTAssertEqual(initial.map(\.state),[.normal,.identicalRemoved,.identicalRemoved,.conflicted,.conflicted,.normal])
        XCTAssertEqual(initial.map(\.displayText),["head","old1","old2","","","tail"])
        XCTAssertEqual(initial.map(\.lineNumber),[1,nil,nil,2,3,4])
        let result = MergeResultPresentation(text:value.result,states:value.sources.resultLocator!.states,navigationMap:value.sources.navigationMap)
        let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:result))
        XCTAssertEqual(projection.cells.filter { $0.state == .conflicted }.count,2)
        XCTAssertGreaterThan(result.states(conflicts:result.conflicts().map(\.range)).filter { $0 == .conflicted }.count,2)
        let block = try XCTUnwrap(result.conflicts().first)
        XCTAssertEqual(projection.sourceRows(intersecting:block.range),[3,4])
    }
    func testSingleSideResolutionKeepsExactRowsForLaterPartialChoice() throws {
        let value = try presentation("head\nold1\nold2\ntail\n","head\nmine1\nmine2\ntail\n","head\ntheirs 🐢\ntheirs2\ntail\n")
        let before = MergeResultPresentation(text:value.result,states:value.sources.resultLocator!.states,navigationMap:value.sources.navigationMap)
        let conflict = try XCTUnwrap(before.conflicts().first)
        let sourceRows = try XCTUnwrap(before.navigationMap.sourceRows(resultRange:conflict.range))
        let mine = try XCTUnwrap(MergeSourceBlockEdit(comparison:value.sources,presentation:before,rows:sourceRows,choice:.mine))
        let resolved = try XCTUnwrap(before.applyingSourceBlock(mine))
        XCTAssertEqual(resolved.text,"head\nmine1\nmine2\ntail\n")
        XCTAssertEqual(resolved.navigationMap.exactResultRange(sourceRows:3..<4),NSRange(location:5,length:6))
        XCTAssertEqual(resolved.navigationMap.exactResultRange(sourceRows:4..<5),NSRange(location:11,length:6))
        let partial = try XCTUnwrap(MergeSourceBlockEdit(comparison:value.sources,presentation:resolved,rows:3..<4,choice:.theirs))
        let after = try XCTUnwrap(resolved.applyingSourceBlock(partial))
        XCTAssertEqual(after.text,"head\ntheirs 🐢\nmine2\ntail\n")
        let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:after))
        XCTAssertEqual(projection.cells.map(\.displayText),["head","old1","old2","theirs 🐢","mine2","tail"])
        XCTAssertEqual(projection.sourceRows(intersecting:after.navigationMap.exactResultRange(sourceRows:4..<5)!),[4])
        XCTAssertEqual(before.conflicts().count,1)
    }
    func testUnknownAndMultiCopyCoordinatesRefuseAlignedProjection() throws {
        let value = try presentation("head\nold\ntail\n","head\nmine\ntail\n","head\ntheirs\ntail\n")
        let result = MergeResultPresentation(text:value.result,states:value.sources.resultLocator!.states,navigationMap:value.sources.navigationMap)
        let rows = try XCTUnwrap(result.navigationMap.sourceRows(resultRange:result.conflicts()[0].range))
        let edit = try XCTUnwrap(MergeSourceBlockEdit(comparison:value.sources,presentation:result,rows:rows,choice:.mineThenTheirs))
        XCTAssertNil(MergeAlignedResultProjection(comparison:value.sources,presentation:try XCTUnwrap(result.applyingSourceBlock(edit))))
        XCTAssertNil(MergeAlignedResultProjection(comparison:value.sources,presentation:result.reconciling("prefix\n" + result.text)))
    }
    func testPartialTypingKeepsEditedRowStateAndExactSerializedOffsets() throws {
        let value = try presentation("head\nline text\ntail\n","head\nline text\ntail\n","head\nline text\ntail\n")
        let original = MergeResultPresentation(text:value.result,states:value.sources.resultLocator!.states,navigationMap:value.sources.navigationMap)
        let changed = try XCTUnwrap(original.replacing(NSRange(location:7,length:1),with:"🐢"))
        let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison:value.sources,presentation:changed))
        XCTAssertEqual(projection.cells[1].state,.edited)
        XCTAssertEqual(projection.cells[1].text,"li🐢e text\n")
        XCTAssertEqual(projection.serializedRanges[2].location,"head\nli🐢e text\n".utf16.count)
    }
    func testNonConflictingRowsMapIndividuallyIncludingRemovedAnchors() throws {
        let value = try presentation("head\nold1\nold2\ntail\n", "head\nnew1\nnew2\ntail\n", "head\nold1\nold2\ntail\n")
        let rows = value.sources.rows
        let removed = try XCTUnwrap(rows.firstIndex { $0.mine.state == .yoursRemoved })
        let added = try XCTUnwrap(rows.firstIndex { $0.mine.displayText == "new1" })
        XCTAssertEqual(value.sources.navigationMap.exactResultRange(sourceRows:removed..<(removed + 1)),NSRange(location:5,length:0))
        XCTAssertEqual(value.sources.navigationMap.exactResultRange(sourceRows:added..<(added + 1)),NSRange(location:5,length:5))
        let result = MergeResultPresentation(text:value.result,states:[],navigationMap:value.sources.navigationMap)
        let edit = try XCTUnwrap(MergeSourceBlockEdit(comparison:value.sources,presentation:result,rows:added..<(added + 1),choice:.theirs))
        XCTAssertEqual(result.applyingSourceBlock(edit)?.text,"head\nnew2\ntail\n")
    }
    func testTheirsOnlyAndDeletionHaveExactWritableMappings() throws {
        for (mine,theirs,state) in [("head\nold\ntail\n","head\nnew\ntail\n",MergeSourceState.theirsAdded),("head\ntail\n","head\nold\ntail\n",.yoursRemoved)] {
            let value = try presentation("head\nold\ntail\n",mine,theirs)
            let row = try XCTUnwrap(value.sources.rows.firstIndex { $0.mine.state == state || $0.theirs.state == state })
            XCTAssertNotNil(value.sources.navigationMap.exactResultRange(sourceRows:row..<(row + 1)))
            XCTAssertEqual(value.sources.navigationMap.exactResultRange(sourceRows:0..<value.sources.rows.count),NSRange(location:0,length:value.result.utf16.count))
        }
    }
    func testNavigationMapsEngineGroupsAcrossMarkerLinesAndUnequalSources() throws {
        let base = "head 🦎\nbase1\nsepA\nbase2\nsepB\nbase3\ntail\n"
        let mine = "head 🦎\nmine1a\nmine1b\nsepA\nmine2\nsepB\nbase3\ntail\n"
        let theirs = "head 🦎\ntheirs1\nsepA\ntheirs2\nsepB\ntheirs3\ntail\n"
        let value = try presentation(base,mine,theirs)
        let blocks = MergeText.conflicts(in:value.result)
        XCTAssertEqual(blocks.count,2)
        for (text,index) in [("mine1a",0),("mine2",1)] {
            let row = try XCTUnwrap(value.sources.rows.firstIndex { $0.mine.displayText == text })
            let mapped = try XCTUnwrap(value.sources.navigationMap.resultRange(sourceRows:row..<(row + 1)))
            XCTAssertEqual(mapped,blocks[index].range)
            let sources = try XCTUnwrap(value.sources.navigationMap.sourceRows(resultRange:blocks[index].range))
            XCTAssertTrue(sources.contains(row))
        }
        XCTAssertEqual(value.sources.navigationMap.entries.first?.resultRange,NSRange(location:0,length:"head 🦎\n".utf16.count))
        let last = try XCTUnwrap(value.sources.navigationMap.entries.last)
        XCTAssertEqual(NSMaxRange(last.resultRange),value.result.utf16.count)
        XCTAssertTrue(value.sources.navigationMap.entries.allSatisfy { $0.sourceRows.upperBound <= value.sources.rows.count && NSMaxRange($0.resultRange) <= value.result.utf16.count })
    }
    func testIgnoredConflictNavigationMapsPlainMinePayload() throws {
        var engine = configuration();engine.options = .init(whitespace:.ignoreAll)
        let value = try SubversionMergePresentation(plan:engine.plan(base:"head\na b\nend\n",mine:"head\nab\nend\n",theirs:"head\na  b\nend\n"))
        let item = try XCTUnwrap(value.sources.ignoredConflicts.first)
        XCTAssertEqual(value.sources.navigationMap.resultRange(sourceRows:1..<2),item.range)
        XCTAssertEqual(value.sources.navigationMap.sourceRows(resultRange:item.range),1..<2)
    }
    func testIgnoredWhitespaceConflictsKeepMineBytesButRetainSourceChoices() throws {
        var engine = configuration(); engine.options = .init(whitespace:.ignoreAll)
        let base = "head 雪🦎\r\nvalue x y\r\n", mine = "head 雪🦎\r\nvaluexy\r\n", theirs = "head 雪🦎\r\nvalue x  y\r\n"
        let value = try SubversionMergePresentation(plan:engine.plan(base:base,mine:mine,theirs:theirs))
        XCTAssertEqual(value.result,mine); XCTAssertFalse(MergeText.hasMarkers(value.result))
        XCTAssertEqual(value.sources.ignoredConflicts.count,1)
        XCTAssertEqual(value.sources.rows.last?.mine.state,.conflictAdded)
        XCTAssertEqual(value.sources.rows.last?.theirs.state,.conflictAdded)
        XCTAssertEqual(value.sources.resultLocator?.states,[.normal,.conflictedIgnored])
        let presentation = MergeResultPresentation(text:value.result,states:value.sources.resultLocator!.states,ignoredConflicts:value.sources.ignoredConflicts)
        let block = try XCTUnwrap(presentation.conflicts().first)
        XCTAssertTrue(block.isIgnored); XCTAssertEqual(block.mine,"valuexy\r\n"); XCTAssertEqual(block.theirs,"value x  y\r\n")
        XCTAssertEqual(block.range.location,"head 雪🦎\r\n".utf16.count)
        XCTAssertEqual(MergeLineStatistics(states:presentation.states(conflicts:[])).conflicted,1)
        XCTAssertEqual(MergePaneSaveAs.sourceText(rows:value.sources.rows,mine:false,keepRemoved:false),theirs)
        XCTAssertEqual(MergeFind.matches("value",in:MergeFindLine.document(value.result,states:presentation.states(conflicts:[])),options:.init(modifiedOnly:true)).count,1)
    }
    func testIgnoredConflictRequiresThreeDistinctValuesInOneSourceChannel() throws {
        var engine = configuration(); engine.options = .init(whitespace:.ignoreAll)
        for (base,mine,theirs,count) in [("a b\n","ab\n","a b\n",0),("a b\n","ab\n","ab\n",0),("a b\n","ab\n","a b\r\n",0),("same\n","same\r\n","same\r",1)] {
            let value = try SubversionMergePresentation(plan:engine.plan(base:base,mine:mine,theirs:theirs))
            XCTAssertEqual(value.sources.ignoredConflicts.count,count)
        }
        let exact = try presentation("a b\n","ab\n","a  b\n")
        XCTAssertTrue(MergeText.hasMarkers(exact.result)); XCTAssertTrue(exact.sources.ignoredConflicts.isEmpty)
    }
    func testCaseRegexAndCommentsRetainIgnoredConflictIdentity() throws {
        var caseEngine = configuration(); caseEngine.options = .init(ignoreCase:true)
        let cases = try SubversionMergePresentation(plan:caseEngine.plan(base:"Title\n",mine:"TITLE\n",theirs:"title\n"))
        XCTAssertEqual(cases.sources.ignoredConflicts.count,1)
        let filter = MergeRegexFilter(name:"Versions",expression:"[0-9]+",replacement:"")
        let filtered = try presentation("v1\n","v2\n","v3\n",filter:filter)
        XCTAssertEqual(filtered.sources.ignoredConflicts.count,1)
        var commentEngine = configuration(); commentEngine.options = .init(ignoreComments:true)
        commentEngine.commentTokens = MergeCommentTokens(line:"//",blockStart:"/*",blockEnd:"*/")
        let comments = try SubversionMergePresentation(plan:commentEngine.plan(base:"code // one\n",mine:"code // two\n",theirs:"code // three\n"))
        XCTAssertEqual(comments.sources.ignoredConflicts.count,1)
    }
    func testIdenticalAddedIgnoredPostpassKeepsPinnedBaseBoundsRule() throws {
        let filter = MergeRegexFilter(name:"Versions",expression:"[0-9]+",replacement:"")
        let value = try presentation("base0\nanchor\n","version1\nanchor\n","version2\nanchor\n",filter:filter)
        XCTAssertEqual(value.sources.ignoredConflicts.count,1)
        XCTAssertEqual(value.sources.ignoredConflicts.first?.base,"anchor\n")
        XCTAssertTrue(value.sources.rows.contains{$0.mine.state == .conflictAdded})
        let eof = try presentation("base0\n","version1\n","version2\n",filter:filter)
        XCTAssertTrue(eof.sources.ignoredConflicts.isEmpty)
    }
    func testMarkerAndIgnoredConflictsShareOrderedNavigationWithoutInventedMarkers() throws {
        var engine = configuration(); engine.options = .init(whitespace:.ignoreAll)
        let value = try SubversionMergePresentation(plan:engine.plan(base:"base\nseparator\nx y\n",mine:"mine\nseparator\nxy\n",theirs:"theirs\nseparator\nx  y\n"))
        let result = MergeResultPresentation(text:value.result,states:value.sources.resultLocator!.states,ignoredConflicts:value.sources.ignoredConflicts)
        let blocks = result.conflicts(); XCTAssertEqual(blocks.map(\.id),[0,1]); XCTAssertEqual(blocks.map(\.isIgnored),[false,true])
        let first = try XCTUnwrap(result.replacing(blocks[0].range,with:blocks[0].replacement(.mine),state:.resolved))
        XCTAssertEqual(first.conflicts().count,1); XCTAssertTrue(first.conflicts()[0].isIgnored)
        XCTAssertFalse(MergeText.hasMarkers(first.text)); XCTAssertEqual(first.ignoredConflicts.first?.range.location,"mine\nseparator\n".utf16.count)
    }
    func testConflictSourceAliasesKeepActualBytesAndDistinctPadding() throws {
        let mine="mine one\r\nmine two\r\n",theirs="theirs\r\n"
        let value=try presentation("base\r\n",mine,theirs)
        XCTAssertTrue(value.sources.rows.contains {$0.mine.state == .conflictAdded})
        XCTAssertTrue(value.sources.rows.contains {$0.theirs.state == .conflictEmpty})
        XCTAssertEqual(MergePaneSaveAs.sourceText(rows:value.sources.rows,mine:true,keepRemoved:false),mine)
        XCTAssertFalse(MergePaneSaveAs.sourceText(rows:value.sources.rows,mine:true,keepRemoved:false).contains("<<<<<<<"))
        XCTAssertEqual(value.sources.rows.compactMap {$0.theirs.lineNumber == nil ? nil:$0.theirs.text}.joined(),theirs)
        let counts=MergeLineStatistics(states:value.sources.rows.map { $0.mine.state })
        XCTAssertEqual(counts.added,2);XCTAssertEqual(counts.removed,1);XCTAssertEqual(counts.conflicted,0)
        let locator=MergeLocatorMap(columns:[value.sources.rows.map {$0.mine.state},value.sources.rows.map {$0.theirs.state}])
        XCTAssertTrue(locator.columns[1].contains {$0.state == .conflictEmpty})
    }
    func testTwoPaneSubversionPresentationRetainsRowsGapsAndTransferBytes() throws {
        let base = "head\r\nold\r\nlast", destination = "head\r\nnew\r\nextra\r\nlast"
        let value = try SubversionComparisonPresentation(plan: configuration().plan(base: base, mine: destination)).alignment
        XCTAssertEqual(value.rows.compactMap { $0.base.lineNumber == nil ? nil : $0.base.text }.joined(), base)
        XCTAssertEqual(value.rows.compactMap { $0.destination.lineNumber == nil ? nil : $0.destination.text }.joined(), destination)
        XCTAssertEqual(value.differences, [1..<3])
        XCTAssertEqual(value.rows[2].base.state, .empty)
        let edit = try FileComparisonEditing.takingOtherRows(value, rows: value.differences[0], targetBase: true)
        XCTAssertEqual(edit.text, destination)
        let display = value.rows.map { $0.destination.displayText + "\n" }.joined() as NSString
        let range = display.range(of: "extra")
        XCTAssertEqual(try FileComparisonEditing.sourceRange(range, cells: value.rows.map(\.destination)), (destination as NSString).range(of: "extra"))
    }
    func testTwoPaneFilteredKeysAndRepeatedLinesKeepOriginalContentAndAnnotationNumbers() throws {
        let filter = MergeRegexFilter(name: "Versions", expression: "[0-9]+", replacement: "")
        let base = "stamp 12\na\na\nold\na", destination = "stamp 81\na\na\nnew\na"
        let value = try SubversionComparisonPresentation(plan: configuration(filter).plan(base: base, mine: destination)).alignment
        XCTAssertEqual(value.rows[0].base.state, .filtered)
        XCTAssertEqual(value.differences, [3..<4])
        XCTAssertEqual(value.rows.map(\.base.text).joined(), base)
        XCTAssertEqual(value.rows.map(\.destination.text).joined(), destination)
        let projection = FileComparisonAlignment(base: base, destination: destination)
        let marks = FileComparisonEditing.Annotations(marked: [3], edited: [3])
        let remapped = marks.remapped(from: projection, to: value, targetBase: false, typing: false)
        XCTAssertEqual(remapped.marked, [3]); XCTAssertEqual(remapped.edited, [3])
    }
    func testIndependentChangesAndOriginalSourceReconstruction() throws {
        let base = "head\nfirst\nmiddle\nsecond\nlast", mine = "head\nMINE\nmiddle\nsecond\nlast", theirs = "head\nfirst\nmiddle\nTHEIRS\nlast"
        let value = try presentation(base, mine, theirs)
        XCTAssertEqual(value.result, "head\nMINE\nmiddle\nTHEIRS\nlast")
        XCTAssertEqual(value.sources.resultLocator?.states, [.normal, .yoursAdded, .normal, .theirsAdded, .normal])
        XCTAssertEqual(value.sources.rows.compactMap { $0.mine.lineNumber == nil ? nil : $0.mine.text }.joined(), mine)
        XCTAssertEqual(value.sources.rows.compactMap { $0.theirs.lineNumber == nil ? nil : $0.theirs.text }.joined(), theirs)
        XCTAssertTrue(value.sources.rows.contains { $0.mine.state == .yoursRemoved && $0.theirs.state == .normal })
        XCTAssertTrue(value.sources.rows.contains { $0.mine.state == .normal && $0.theirs.state == .theirsRemoved })
    }
    func testIdenticalChangesAddAddAndUnequalConflictsPreserveSources() throws {
        let identical = try presentation("base\n", "changed\n", "changed\n")
        XCTAssertEqual(identical.result, "changed\n")
        XCTAssertEqual(identical.sources.rows.map(\.mine.state), [.identicalRemoved, .identicalAdded])
        let added = try presentation("", "mine\n", "theirs\nmore\n")
        XCTAssertEqual(MergeText.conflicts(in: added.result).count, 1)
        XCTAssertEqual(added.sources.resultLocator?.states.count, MergeRegexFilters.lines(added.result).count)
        XCTAssertTrue(added.sources.resultLocator?.states.allSatisfy { $0 == .conflicted } == true)
        XCTAssertEqual(added.sources.rows.last?.mine.state, .conflictEmpty)
        XCTAssertNil(added.sources.rows.last?.mine.lineNumber)
        XCTAssertEqual(added.sources.rows.compactMap { $0.mine.lineNumber == nil ? nil : $0.mine.text }.joined(), "mine\n")
        XCTAssertEqual(added.sources.rows.compactMap { $0.theirs.lineNumber == nil ? nil : $0.theirs.text }.joined(), "theirs\nmore\n")
    }
    func testResolvedFirstChildPadsRemovedBaseWithoutResolvingSharedParent() throws {
        let mine = "shared1\nshared2\nmine\n", theirs = "shared1\nshared2\ntheirs\n"
        let value = try presentation("base\n", mine, theirs)
        XCTAssertEqual(value.sources.rows.count, 5)
        XCTAssertEqual(value.sources.rows[0].mine.text, "base\n")
        XCTAssertEqual(value.sources.rows[1].mine.text, "")
        XCTAssertEqual(value.sources.rows[1].mine.state, .identicalRemoved)
        XCTAssertNil(value.sources.rows[1].mine.lineNumber)
        XCTAssertEqual(value.sources.rows.compactMap { $0.mine.lineNumber == nil ? nil : $0.mine.text }.joined(), mine)
        XCTAssertEqual(value.sources.rows.compactMap { $0.theirs.lineNumber == nil ? nil : $0.theirs.text }.joined(), theirs)
        let blocks = MergeText.conflicts(in: value.result)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].mine, mine); XCTAssertEqual(blocks[0].theirs, theirs)
        XCTAssertEqual(blocks[0].replacement(.mineThenTheirs), mine + theirs)
    }
    func testFilteredCommonChoosesOriginalMineAndRetainsIgnoredConflict() throws {
        let filter = MergeRegexFilter(name: "Versions", expression: "[0-9]+", replacement: "")
        let value = try presentation("version 12\r\n", "version 81\r\n", "version 90\r\n", filter: filter)
        XCTAssertEqual(value.result, "version 81\r\n")
        XCTAssertEqual(value.sources.rows[0].mine.state, .conflictAdded)
        XCTAssertEqual(value.sources.ignoredConflicts.count,1)
        XCTAssertEqual(value.sources.rows[0].theirs.text, "version 90\r\n")
        XCTAssertFalse(MergeText.hasMarkers(value.result))
    }
    func testEveryEndingCanDelimitConflictMarkersAndRetainsSourceText() throws {
        for ending in MergeLineEnding.allCases {
            let mine = "mine" + ending.rawValue, theirs = "theirs" + ending.rawValue
            let value = try presentation("base" + ending.rawValue, mine, theirs)
            let blocks = MergeText.conflicts(in: value.result)
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks.first?.replacement(.mine), mine)
            XCTAssertEqual(blocks.first?.replacement(.theirs), theirs)
        }
    }
    func testEngineBackedDocumentAndSavePreserveRepositoryUntilExplicitResolution() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEngineMerge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = GitRepository(root: folder, executable: URL(fileURLWithPath: "/usr/bin/git")), file = folder.appendingPathComponent("sample.txt")
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Engine QA"), ("user.email", "engine@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.autocrlf", "false")] { _ = try await repository.run(["config", key, value]) }
        try Data("version 1\nbase".utf8).write(to: file)
        _ = try await repository.run(["add", "--", "sample.txt"]); _ = try await repository.run(["commit", "-m", "base"])
        _ = try await repository.run(["checkout", "-b", "side"])
        try Data("version 3\ntheirs".utf8).write(to: file); _ = try await repository.run(["commit", "-am", "theirs"])
        _ = try await repository.run(["checkout", "main"])
        try Data("version 2\nmine".utf8).write(to: file); _ = try await repository.run(["commit", "-am", "mine"])
        _ = try await repository.run(["merge", "side"], successfulExitCodes: 0...1)
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: folder.appendingPathComponent(".git/index")), working = try Data(contentsOf: file)
        let filter = MergeRegexFilter(name: "Versions", expression: "[0-9]+", replacement: "")
        let document = try await repository.textConflictDocument(path: "sample.txt", engine: configuration(filter))
        XCTAssertNotNil(document.mergeSources)
        XCTAssertEqual(document.mergeSources?.rows[0].mine.state, .conflictAdded)
        XCTAssertEqual(document.mergeSources?.ignoredConflicts.count,1)
        XCTAssertEqual(try Data(contentsOf: file), working)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(".git/index")), index)
        var edit = MergeResultPresentation(text:document.initialResult,states:document.mergeSources!.resultLocator!.states,ignoredConflicts:document.mergeSources!.ignoredConflicts)
        for block in edit.conflicts(document:document).reversed() { edit = try XCTUnwrap(edit.replacing(block.range,with:block.replacement(.mine),state:.resolved)) }
        XCTAssertTrue(edit.conflicts().isEmpty)
        let result = edit.text
        XCTAssertEqual(result, "version 2\nmine")
        let saved = try await repository.saveTextConflict(document, result: result, markResolved: false)
        XCTAssertNotNil(saved.mergeSources)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(".git/index")), index)
        _ = try await repository.saveTextConflict(saved, result: result, markResolved: true, ignoredConflictsResolved:edit.ignoredConflicts.isEmpty)
        let stages = try await repository.conflicts(), afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertTrue(stages.isEmpty); XCTAssertEqual(afterHead, head)
        XCTAssertEqual(try Data(contentsOf: file), Data(result.utf8))
    }
}

final class MergeLocatorTests: XCTestCase {
    func testLocatorCompressesActualRowsAndUsesLongestPane() {
        let map = MergeLocatorMap(columns: [[.normal, .normal, .removed, .removed, .empty], [], [.normal, .added]])
        XCTAssertEqual(map.lineCount, 5)
        XCTAssertEqual(map.columns[0].map(\.rows), [0..<2, 2..<4, 4..<5])
        XCTAssertEqual(map.columns[0].map(\.state), [.normal, .removed, .empty])
        XCTAssertTrue(map.columns[1].isEmpty)
        XCTAssertEqual(map.row(at: -2), 0); XCTAssertEqual(map.row(at: 0.5), 2)
        XCTAssertEqual(map.row(at: 2), 4); XCTAssertEqual(map.row(at: .nan), 0)
        XCTAssertEqual(MergeLocatorMap(columns: []).row(at: 1), 0)
    }
    func testLocatorRetainsInitialEngineColorsTracksEditsAndConflicts() {
        let text = "雪🦎\r\nadded\r\ntail", first = "雪🦎\r\n".utf16.count, added = "added\r\n".utf16.count
        let result = MergeLocatorResult(text: text, spans: [(0..<first, .filtered), (first..<first + added, .added), (first + added..<text.utf16.count, .normal)])
        XCTAssertEqual(result.states, [.filtered, .added, .normal])
        XCTAssertEqual(result.states(for: text, conflicts: []), result.states)
        let changed = "雪🦎\r\nmanual\r\nextra\r\ntail"
        XCTAssertEqual(result.states(for: changed, conflicts: []), [.filtered, .added, .added, .normal])
        let range = (changed as NSString).range(of: "manual\r\nextra\r\n")
        XCTAssertEqual(result.states(for: changed, conflicts: [range]), [.filtered, .conflicted, .conflicted, .normal])
        XCTAssertEqual(result.states(for: "", conflicts: []), [])
    }
    func testSourceDefaultsAndSavedLocatorChoicesUsePrivatePreferences() {
        let suite = "TurtleGit.Locator." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MergeLocatorPreferences.load(from: defaults), .init(visible: true, fishEye: true))
        let hidden = MergeLocatorPreferences(visible: false, fishEye: false)
        hidden.save(to: defaults); XCTAssertEqual(MergeLocatorPreferences.load(from: defaults), hidden)
        MergeLocatorPreferences().save(to: defaults); XCTAssertEqual(MergeLocatorPreferences.load(from: defaults), .init())
    }
}
