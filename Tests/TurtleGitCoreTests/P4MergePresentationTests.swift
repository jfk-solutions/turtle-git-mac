import XCTest
@testable import TurtleGitCore

final class P4MergePresentationTests:XCTestCase {
    private func fixture() throws -> (SubversionMergePresentation, MergeResultPresentation) {
        let plan=SubversionDiffPlan(segments:[
            .init(kind:.common,base:0..<1,mine:0..<1,theirs:0..<1),
            .init(kind:.conflict,base:1..<2,mine:1..<3,theirs:1..<2),
            .init(kind:.common,base:2..<3,mine:3..<4,theirs:2..<3),
            .init(kind:.latest,base:3..<4,mine:4..<5,theirs:3..<4)
        ],base:["head 🐢\r\n","base\r\n","middle\r\n","end"],mine:["head 🐢\r\n","mine one\r\n","mine two\r\n","middle\r\n","end"],theirs:["head 🐢\r\n","theirs\r\n","middle\r\n","new end"])
        let sources=try SubversionMergePresentation(plan:plan)
        return (sources,MergeResultPresentation(text:sources.result,comparison:sources.sources))
    }
    func testRealSourceCoordinatesAndUnequalRegions() throws {
        let (source,_)=try fixture(),chunks=source.sources.chunks
        XCTAssertEqual(chunks.count,2)
        XCTAssertEqual(chunks[0].mine,"mine one\r\nmine two\r\n")
        XCTAssertEqual(chunks[0].baseRange,NSRange(location:"head 🐢\r\n".utf16.count,length:"base\r\n".utf16.count))
        XCTAssertEqual(chunks[0].mineRange.length,"mine one\r\nmine two\r\n".utf16.count)
        XCTAssertTrue(chunks[0].conflict);XCTAssertFalse(chunks[1].conflict)
        XCTAssertEqual(chunks[1].mineRange.location,"head 🐢\r\nmine one\r\nmine two\r\nmiddle\r\n".utf16.count)
    }
    func testToggleEachInputAndCombinationOrderWithoutTouchingNextChunk() throws {
        let (source,initial)=try fixture(),chunk=source.sources.chunks[0],last=source.sources.chunks[1]
        let a=try XCTUnwrap(initial.togglingInput(.theirs,chunk:chunk,lineEnding:.crlf))
        let b=try XCTUnwrap(a.togglingInput(.mine,chunk:chunk,lineEnding:.crlf))
        XCTAssertEqual(b.text,"head 🐢\r\ntheirs\r\nmine one\r\nmine two\r\nmiddle\r\nnew end")
        XCTAssertEqual(b.selectedInputs(for:chunk),[.theirs,.mine])
        let c=try XCTUnwrap(b.togglingInput(.theirs,chunk:chunk,lineEnding:.crlf))
        XCTAssertEqual(c.selectedInputs(for:chunk),[.mine])
        let d=try XCTUnwrap(c.togglingInput(.mine,chunk:chunk,lineEnding:.crlf))
        XCTAssertEqual(d.text,"head 🐢\r\nmiddle\r\nnew end")
        XCTAssertEqual(d.navigationMap.exactResultRange(sourceRows:chunk.sourceRows)?.length,0)
        let e=try XCTUnwrap(d.togglingInput(.base,chunk:chunk,lineEnding:.crlf))
        XCTAssertEqual(e.text,"head 🐢\r\nbase\r\nmiddle\r\nnew end")
        XCTAssertEqual((e.text as NSString).substring(with:try XCTUnwrap(e.navigationMap.exactResultRange(sourceRows:last.sourceRows))),"new end")
        XCTAssertTrue(e.conflicts().isEmpty)
    }
    func testWholeFileBaseAndYoursKeepSubsequentChunkSelection() throws {
        let (source,presentation)=try fixture(),chunks=source.sources.chunks
        let base="head 🐢\r\nbase\r\nmiddle\r\nend"
        let selected=presentation.usingWholeInput(.base,text:base,chunks:chunks)
        XCTAssertEqual(selected.text,base)
        XCTAssertEqual(selected.selectedInputs(for:chunks[1]),[.base])
        let removed=try XCTUnwrap(selected.togglingInput(.base,chunk:chunks[1],lineEnding:.crlf))
        let replaced=try XCTUnwrap(removed.togglingInput(.theirs,chunk:chunks[1],lineEnding:.crlf))
        XCTAssertEqual(replaced.text,"head 🐢\r\nbase\r\nmiddle\r\nnew end")
    }
    func testManualEditsClearChoiceButKeepExactChunkAndBoundaryEditsRefuseGuessing() throws {
        let (source,initial)=try fixture(),chunk=source.sources.chunks[0]
        let choice=try XCTUnwrap(initial.togglingInput(.theirs,chunk:chunk,lineEnding:.crlf))
        let range=try XCTUnwrap(choice.navigationMap.exactResultRange(sourceRows:chunk.sourceRows))
        let edited=try XCTUnwrap(choice.replacing(NSRange(location:range.location,length:2),with:"manual",state:.edited))
        XCTAssertEqual(edited.selectedInputs(for:chunk),[])
        XCTAssertNotNil(edited.togglingInput(.base,chunk:chunk,lineEnding:.crlf))
        let ambiguous=try XCTUnwrap(choice.replacing(NSRange(location:range.location-1,length:range.length+2),with:"crossed",state:.edited))
        XCTAssertNil(ambiguous.togglingInput(.mine,chunk:chunk,lineEnding:.crlf))
    }
    func testIdenticalSourceSelectionsDoNotDuplicateText() throws {
        let (source,presentation)=try fixture(),original=source.sources.chunks[0]
        let chunk=MergeSourceChunk(id:original.id,sourceRows:original.sourceRows,baseRange:original.baseRange,theirsRange:original.theirsRange,mineRange:original.mineRange,base:"same",theirs:"same",mine:"same",conflict:true)
        let a=try XCTUnwrap(presentation.togglingInput(.base,chunk:chunk,lineEnding:.lf))
        let b=try XCTUnwrap(a.togglingInput(.theirs,chunk:chunk,lineEnding:.lf))
        let c=try XCTUnwrap(b.togglingInput(.mine,chunk:chunk,lineEnding:.lf))
        XCTAssertEqual(c.selectedInputs(for:chunk),[.base,.theirs,.mine])
        let range=try XCTUnwrap(c.navigationMap.exactResultRange(sourceRows:chunk.sourceRows))
        XCTAssertEqual((c.text as NSString).substring(with:range),"same")
    }
    func testClassicSourceChoiceRetainsOriginalChunkMetadata() throws {
        let (source,presentation)=try fixture(),chunk=source.sources.chunks[0]
        let edit=try MergeAlignedSourceBlockEdit(comparison:source.sources,presentation:presentation,rows:chunk.sourceRows,choice:.mine,lineEnding:.crlf)
        XCTAssertEqual(edit.comparison.chunks.map(\.id),source.sources.chunks.map(\.id))
        XCTAssertEqual(edit.comparison.chunks.first?.base,chunk.base)
    }
    func testCandidateProjectionKeepsConflictBytesAndDisplaysEverySource() throws {
        let (source,initial)=try fixture(),projection=P4MergeResultProjection(presentation:initial,chunks:source.sources.chunks,lineEnding:.crlf)
        XCTAssertFalse(projection.text.contains("<<<<<<<"))
        XCTAssertTrue(projection.text.contains("base\r\ntheirs\r\nmine one\r\nmine two\r\n"))
        XCTAssertTrue(initial.text.contains("<<<<<<<"))
        let record=try XCTUnwrap(projection.records.first(where:{$0.unresolved}))
        XCTAssertEqual(record.candidates.map(\.source),[.base,.theirs,.mine])
        XCTAssertEqual(projection.displayRange(record.serialized),record.display)
    }
    func testCandidateTypingResolvesOnlyThatRegionAndPreservesFollowingChange() throws {
        let (source,initial)=try fixture(),projection=P4MergeResultProjection(presentation:initial,chunks:source.sources.chunks,lineEnding:.crlf)
        let match=(projection.text as NSString).range(of:"mine one")
        let edit=try XCTUnwrap(projection.edit(match,replacement:"typed 🐢"))
        let next=try XCTUnwrap(initial.replacing(edit.range,with:edit.replacement,state:.edited))
        XCTAssertFalse(next.text.contains("<<<<<<<"))
        XCTAssertTrue(next.text.contains("base\r\ntheirs\r\ntyped 🐢\r\nmine two\r\n"))
        XCTAssertTrue(next.text.hasSuffix("middle\r\nnew end"))
        XCTAssertNotNil(next.navigationMap.exactResultRange(sourceRows:source.sources.chunks[1].sourceRows))
        let display=P4MergeResultProjection(presentation:next,chunks:source.sources.chunks,lineEnding:.crlf)
        XCTAssertEqual(display.text,next.text)
    }
    func testProjectedBoundaryAndEOFEditsPreserveOrdinaryBytes() throws {
        let (source,initial)=try fixture(),projection=P4MergeResultProjection(presentation:initial,chunks:source.sources.chunks,lineEnding:.crlf)
        let suffix=try XCTUnwrap(projection.edit(NSRange(location:projection.text.utf16.count,length:0),replacement:"!"))
        let changed=try XCTUnwrap(initial.replacing(suffix.range,with:suffix.replacement,state:.edited))
        XCTAssertEqual(changed.text,initial.text+"!")
        let prefix=try XCTUnwrap(projection.edit(NSRange(location:0,length:0),replacement:"// note\r\n"))
        let prefixed=try XCTUnwrap(initial.replacing(prefix.range,with:prefix.replacement,state:.edited))
        XCTAssertEqual(prefixed.text,"// note\r\n"+initial.text)
        let range=NSRange(location:0,length:(projection.text as NSString).range(of:"mine two").location+3)
        let edit=try XCTUnwrap(projection.edit(range,replacement:"replacement\r\n"))
        let next=try XCTUnwrap(initial.replacing(edit.range,with:edit.replacement,state:.edited))
        XCTAssertTrue(next.text.hasSuffix("middle\r\nnew end"))
        XCTAssertFalse(next.text.contains("<<<<<<<"))
    }

}
