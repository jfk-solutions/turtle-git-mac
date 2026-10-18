// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class MergeExternalSourceTests: XCTestCase {
    private func fixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitExternalSources-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
    private func source(_ url:URL,bytes:Data=Data("accepted\n".utf8),missing:Bool=false)->MergeExternalSource {
        .init(id:"mine",url:url,expectedBytes:bytes,expectedMissing:missing)
    }
    private func probe(_ sources:[MergeExternalSource],_ previous:[String:MergeExternalSourceObservation]=[:]) throws -> MergeExternalSourceProbe {
        try MergeExternalSources.probe(sources,previous:previous,cancellation:OperationCancellation())
    }
    private var engine:SubversionMergeConfiguration {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return .init(executable:root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"),runtimeRoot:root.appendingPathComponent("build/git-runtime/Git"))
    }
    func testFirstObservationRetainsAcceptedReadRaceAndAcknowledgesOnce() throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("mine"),accepted=Data("accepted\n".utf8)
        try Data("external before observer\n".utf8).write(to:url)
        let value=try probe([source(url,bytes:accepted)])
        XCTAssertEqual(value.changed,["mine"]);XCTAssertNotNil(value.observations["mine"])
        XCTAssertTrue(try probe([source(url,bytes:accepted)],value.observations).changed.isEmpty)
        XCTAssertEqual(try Data(contentsOf:url),Data("external before observer\n".utf8))
    }
    func testMetadataAndEqualByteAtomicReplacementRemainObservable() throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("mine"),bytes=Data("accepted\n".utf8)
        try bytes.write(to:url);let initial=try probe([source(url)])
        XCTAssertTrue(initial.changed.isEmpty)
        let date=try XCTUnwrap(try FileManager.default.attributesOfItem(atPath:url.path)[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate:date.addingTimeInterval(5)],ofItemAtPath:url.path)
        let touched=try probe([source(url)],initial.observations);XCTAssertEqual(touched.changed,["mine"])
        try bytes.write(to:url,options:.atomic)
        let replaced=try probe([source(url)],touched.observations);XCTAssertEqual(replaced.changed,["mine"])
        XCTAssertTrue(try probe([source(url)],replaced.observations).changed.isEmpty)
    }
    func testMissingAttributeQueriesAreIgnoredButAppearanceAndTypeReplacementWarn() throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("mine"),missing=source(url,bytes:Data(),missing:true)
        XCTAssertTrue(try probe([missing]).changed.isEmpty)
        try Data("appeared\n".utf8).write(to:url)
        XCTAssertEqual(try probe([missing]).changed,["mine"])
        let accepted=source(url,bytes:Data("appeared\n".utf8)),initial=try probe([accepted])
        try FileManager.default.removeItem(at:url)
        let gone=try probe([accepted],initial.observations)
        XCTAssertTrue(gone.changed.isEmpty);XCTAssertEqual(gone.observations,initial.observations)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        XCTAssertEqual(try probe([accepted],initial.observations).changed,["mine"])
        XCTAssertEqual(try probe([accepted]).changed,["mine"],"An available replacement's attributes cannot be silently ignored because reading its contents fails")
    }
    func testCancellationDoesNotAcknowledgeAnyPartialResult() throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("mine");try Data("accepted\n".utf8).write(to:url)
        let baseline=try probe([source(url)]),token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try MergeExternalSources.probe([source(url)],previous:baseline.observations,cancellation:token))
        XCTAssertTrue(try probe([source(url)],baseline.observations).changed.isEmpty)
    }
    func testKeptDraftForcesDirtyWithoutAcceptingOutsideWriteBaseline() throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let left=root.appendingPathComponent("left"),right=root.appendingPathComponent("right")
        try Data("left\n".utf8).write(to:left);try Data("accepted\n".utf8).write(to:right)
        let document=try WorkingFileComparison(base:left,destination:right).read()
        var drafts=FileComparisonDrafts(document);drafts.markExternallyChanged(base:false)
        XCTAssertTrue(drafts.isDirty(base:false));XCTAssertFalse(drafts.isDirty(base:true))
        XCTAssertEqual(drafts.text(base:false),document.destination.text)
        try Data("external\n".utf8).write(to:right)
        XCTAssertThrowsError(try FileComparisonEditing.saveWorkingContent(at:right,original:document.destination,text:drafts.text(base:false)!,encoding:.utf8))
        XCTAssertEqual(try Data(contentsOf:right),Data("external\n".utf8))
    }
    func testThreeFileRawSourceReceiptsSurviveSaveAndRetainedCopyCannotAliasInputs() async throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let base=root.appendingPathComponent("base"),mine=root.appendingPathComponent("mine"),theirs=root.appendingPathComponent("theirs"),output=root.appendingPathComponent("result")
        for (url,text) in [(base,"one\ntwo\nthree\n"),(mine,"ONE\ntwo\nthree\n"),(theirs,"one\ntwo\nTHREE\n")] {try Data(text.utf8).write(to:url)}
        let merge=try WorkingTextMerge(base:base,theirs:theirs,mine:mine,merged:output),document=try await merge.read(engine:engine)
        XCTAssertEqual(Set(document.externalSources.map(\.id)),["base","mine","theirs"])
        XCTAssertFalse(document.externalSources.contains {$0.url==output})
        for source in document.externalSources {XCTAssertEqual(source.expectedBytes,try Data(contentsOf:source.url))}
        try Data("external source\n".utf8).write(to:mine)
        do {_ = try await merge.save(document,result:"kept result\n");XCTFail("Normal Save accepted external source")} catch TextConflictFailure.changedWorkingFile {}
        let copy=root.appendingPathComponent("independent"),saved=try await merge.saveRetainedResultCopy(to:copy,document:document,result:"kept result\n")
        XCTAssertEqual(try Data(contentsOf:copy),Data("kept result\n".utf8));XCTAssertEqual(saved.externalSources.count,3)
        let alias=root.appendingPathComponent("alias");try FileManager.default.linkItem(at:mine,to:alias)
        for forbidden in [base,mine,theirs,output,alias] {
            do {_ = try await merge.saveRetainedResultCopy(to:forbidden,document:document,result:"unsafe\n");XCTFail("Accepted source/output alias: \(forbidden.path)")} catch TextConflictFailure.changedWorkingFile {}
        }
        XCTAssertEqual(try Data(contentsOf:mine),Data("external source\n".utf8));XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        // Default output is original Mine, even after its source pane Save As.
        // Rebinding must not authorize an outside write to that original output.
        let defaultMerge=try WorkingTextMerge(base:base,theirs:theirs,mine:mine)
        let defaultDocument=try await defaultMerge.read(engine:engine)
        let retained=root.appendingPathComponent("rebound-mine"),retainedBytes=try Data(contentsOf:mine)
        try retainedBytes.write(to:retained)
        let target=try SavedMergePane(url:retained,writtenBytes:retainedBytes,encoding:defaultDocument.mineEncoding)
        try Data("outside default output\n".utf8).write(to:mine)
        try await defaultMerge.bindSource(mine:true,target:target)
        do {_ = try await defaultMerge.save(defaultDocument,result:"must not overwrite\n");XCTFail("Source Save As discarded the original default-output receipt")} catch TextConflictFailure.changedWorkingFile {}
        XCTAssertEqual(try Data(contentsOf:mine),Data("outside default output\n".utf8))
        XCTAssertEqual(try Data(contentsOf:retained),retainedBytes)
        // An accepted result write to the rebound source advances that source
        // from the write receipt, without borrowing later outside disk bytes.
        let reboundDocument=try await defaultMerge.read(engine:engine)
        let reboundSaved=try await defaultMerge.saveTo(retained,document:reboundDocument,result:"owned rebound result\n")
        let advanced=try target.recordingOwnedResult(reboundSaved,at:retained)
        XCTAssertEqual(advanced.content.bytes,Data("owned rebound result\n".utf8))
        try Data("outside after owned result\n".utf8).write(to:retained)
        XCTAssertThrowsError(try advanced.validate())
        XCTAssertEqual(advanced.content.bytes,Data("owned rebound result\n".utf8))
        XCTAssertThrowsError(try target.recordingOwnedResult(reboundSaved,at:output))
    }
}
