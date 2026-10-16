import XCTest
@testable import TurtleGitCore

final class MergeTerminalRecordTests: XCTestCase {
    private var root:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()}
    func alignment(_ base:String,_ mine:String,ignoreEndings:Bool = true)throws->FileComparisonAlignment {
        var config=SubversionMergeConfiguration(executable:root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"),runtimeRoot:root.appendingPathComponent("build/git-runtime/Git"))
        config.options = .init(ignoreEndings:ignoreEndings)
        return try SubversionComparisonPresentation(plan:config.plan(base:base,mine:mine)).alignment
    }
    func testEveryEndingAndEmptyFileHasShownNormalNoEndingRecordOnlyInTwoPane()throws {
        for text in [""] + MergeLineEnding.allCases.map({"head"+$0.rawValue}) {
            let value=try alignment(text,text)
            let last=try XCTUnwrap(value.rows.last)
            XCTAssertEqual(last.base.text,"");XCTAssertEqual(last.destination.text,"")
            XCTAssertEqual(last.base.lineNumber,text.isEmpty ? 1:2);XCTAssertEqual(last.destination.lineNumber,last.base.lineNumber)
            XCTAssertEqual(last.base.state,.normal);XCTAssertFalse(last.base.hiddenByComparison);XCTAssertFalse(last.destination.hiddenByComparison)
            XCTAssertEqual(value.rows.filter{$0.base.hasSourceCoordinate}.map(\.base.text).joined(),text)
            XCTAssertTrue(value.differences.isEmpty)
            let combined=OnePaneFileComparison(alignment:value)
            XCTAssertEqual(combined.cells.count,text.isEmpty ? 0:1);XCTAssertEqual(combined.sourceSaveText,text)
        }
    }
    func testOneTerminalRecordIsAnOrdinaryAddedOrRemovedDifference()throws {
        for ignore in [false,true] {
            for swapped in [false,true] {
                let a=swapped ? "head":"head\n",b=swapped ? "head\n":"head"
                let value=try alignment(a,b,ignoreEndings:ignore),last=try XCTUnwrap(value.rows.last)
                XCTAssertEqual((swapped ? last.destination:last.base).lineNumber,2)
                XCTAssertEqual((swapped ? last.destination:last.base).state,swapped ? .added:.removed)
                XCTAssertEqual((swapped ? last.base:last.destination).state,.empty)
                XCTAssertEqual(value.rows.filter{$0.base.hasSourceCoordinate}.map(\.base.text).joined(),a)
                XCTAssertEqual(value.rows.filter{$0.destination.hasSourceCoordinate}.map(\.destination.text).joined(),b)
                XCTAssertTrue(value.differences.last?.contains(value.rows.count-1)==true)
                let combined=OnePaneFileComparison(alignment:value)
                XCTAssertFalse(combined.cells.contains {$0.text.isEmpty});XCTAssertEqual(combined.sourceSaveText,b)
            }
        }
    }
    func testTerminalRecordFillsFirstTrailingGapInsteadOfAddingAnotherRow()throws {
        for swapped in [false,true] {
            let a=swapped ? "right\nmore\nlast":"left\n",b=swapped ? "left\n":"right\nmore\nlast"
            let value=try alignment(a,b)
            XCTAssertEqual(value.rows.count,3)
            let terminal=swapped ? value.rows[1].destination:value.rows[1].base
            XCTAssertEqual(terminal.text,"");XCTAssertEqual(terminal.lineNumber,2);XCTAssertEqual(terminal.state,swapped ? .added:.removed)
            XCTAssertEqual(value.rows.filter{$0.base.hasSourceCoordinate}.map(\.base.text).joined(),a)
            XCTAssertEqual(value.rows.filter{$0.destination.hasSourceCoordinate}.map(\.destination.text).joined(),b)
            XCTAssertEqual(OnePaneFileComparison(alignment:value).sourceSaveText,b)
        }
    }
    func testEmptyFileTerminalRecordFillsOnlyOccupiedPeerRow()throws {
        let value=try alignment("","x")
        XCTAssertEqual(value.rows.count,1);XCTAssertEqual(value.rows[0].base.lineNumber,1)
        XCTAssertEqual(value.rows[0].base.state,.removed);XCTAssertEqual(value.rows[0].destination.text,"x")
        XCTAssertEqual(OnePaneFileComparison(alignment:value).cells.map(\.text),["x"])
    }
    func testTerminalCaretCoordinatesAndTypingKeepOriginalCRLFAndEncoding()throws {
        let text="head\r\n",value=try alignment(text,text),cells=value.rows.map(\.destination)
        let at="head\n".utf16.count
        XCTAssertEqual(try FileComparisonEditing.sourceRange(NSRange(location:at,length:0),cells:cells),NSRange(location:text.utf16.count,length:0))
        XCTAssertEqual(FileComparisonEditing.displayOffset(sourceOffset:text.utf16.count,cells:cells),at)
        let edit=try FileComparisonInPlaceEdit(alignment:value,base:false,range:NSRange(location:at,length:0),replacement:"🐢")
        XCTAssertEqual(edit.text,"head\r\n🐢");XCTAssertEqual(edit.alignment.rows.map(\.base.text),value.rows.map(\.base.text))
        XCTAssertEqual(edit.alignment.rows.last?.destination.state,.edited)
        let bytes=try ComparisonTextEncoding.utf16LEBOM.encode(edit.text)
        XCTAssertEqual(bytes.prefix(2),Data([0xff,0xfe]));XCTAssertEqual(ComparisonTextEncoding.utf16LEBOM.decode(bytes),edit.text)
    }
    func testTypingEmptyTerminalAndMultilineInsertionDoNotSaveDisplayLF()throws {
        let empty=try alignment("","")
        let edit=try FileComparisonInPlaceEdit(alignment:empty,base:false,range:NSRange(location:0,length:0),replacement:"first\nsecond")
        XCTAssertEqual(edit.text,"first\nsecond");XCTAssertEqual(edit.alignment.rows.filter{$0.destination.hasSourceCoordinate}.map(\.destination.text).joined(),edit.text)
        let ended=try alignment("head\n","head\n")
        let inserted=try FileComparisonInPlaceEdit(alignment:ended,base:false,range:NSRange(location:5,length:0),replacement:"tail\n")
        XCTAssertEqual(inserted.text,"head\ntail\n");XCTAssertEqual(inserted.alignment.rows.last?.destination.text,"")
    }
    func testAcceptingAnAddedEOFRecordRepairsPreviousUnterminatedLine()throws {
        let value=try alignment("head\n","head")
        let result=try FileComparisonEditing.takingOtherRows(value,rows:1..<2,targetBase:false)
        XCTAssertEqual(result.text,"head"+MergeLineEndings.predominantStyle(in:"head").rawValue)
        XCTAssertEqual(result.caret,result.text.utf16.count)
        XCTAssertEqual(value.rows[0].destination.text,"head")
    }
}
