// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
@testable import TurtleGitCore

final class ImageSelectionDocumentTests:XCTestCase {
    private func fixture()throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-image-selection-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
    private func invocation(_ root:URL,result:String?="output",extra:[String]=[])throws->ImageToolInvocation {
        var args=["--image-tool","--base","base","--mine","mine","--theirs","theirs"]
        if let result {args += ["--result",result]};args+=extra
        return try XCTUnwrap(ImageToolInvocation.parse(arguments:args,currentDirectory:root.path))
    }
    private func writeInputs(_ root:URL)throws->[ImageConflictSide:Data] {
        let gif=try ImageFrameTests().sequence(type:"com.compuserve.gif" as CFString,colors:[.red,.blue],delays:[0.1,0.2])
        let values:[ImageConflictSide:Data]=[.base:Data(),.mine:Data([0,255,0,1,2,3,128]),.theirs:gif]
        for (side,name) in [(ImageConflictSide.base,"base"),(.mine,"mine"),(.theirs,"theirs")] {try values[side]!.write(to:root.appendingPathComponent(name))}
        return values
    }
    func testUnsupportedAndEmptyExistingContainersRemainSelectableWithoutDecoding()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let original=try writeInputs(root),document=try ImageSelectionDocument.capture(invocation:invocation(root))
        XCTAssertEqual(document.selectionBytes(.mine),original[.mine]);XCTAssertNil(document.image(.mine))
        XCTAssertEqual(document.selectionBytes(.base),Data());XCTAssertNil(document.image(.base))
        XCTAssertEqual(document.image(.theirs)?.frameCount,2,"Selecting animated images must copy the full original container")
        for side in ImageConflictSide.allCases {
            let target=root.appendingPathComponent(side.rawValue+"-result")
            let loaded=try ImageSelectionDocument.capture(invocation:invocation(root,result:target.path))
            let saved=try loaded.select(side)
            XCTAssertEqual(saved.selectedSide,side);XCTAssertEqual(try Data(contentsOf:target),original[side])
            XCTAssertEqual(saved.output?.content.bytes,original[side])
        }
        for (side,name) in [(ImageConflictSide.base,"base"),(.mine,"mine"),(.theirs,"theirs")] {XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(name)),original[side])}
    }
    func testMetafileSelectionCopiesOriginalRecordsWithoutRasterizing()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try writeInputs(root)
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile/wmf-bitmap16-rop-cc.wmf")
        let original=try Data(contentsOf:fixture)
        try original.write(to:root.appendingPathComponent("mine"))
        let captured=try ImageSelectionDocument.capture(invocation:invocation(root))
        let selected=try captured.select(.mine)
        XCTAssertEqual(selected.selectionBytes(.mine),original)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("output")),original)
    }
    func testMissingUnreadableAndExistingEmptySourcesAreDistinct()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data().write(to:root.appendingPathComponent("base"))
        try FileManager.default.createDirectory(at:root.appendingPathComponent("mine"),withIntermediateDirectories:false)
        let document=try ImageSelectionDocument.capture(invocation:invocation(root))
        XCTAssertEqual(document.selectionBytes(.base),Data());XCTAssertFalse(document.inputs[.base]!.isDeleted)
        XCTAssertNil(document.selectionBytes(.mine));XCTAssertNotNil(document.inputFailures[.mine]);XCTAssertNil(document.inputs[.mine])
        XCTAssertNil(document.selectionBytes(.theirs));XCTAssertTrue(document.inputs[.theirs]!.isDeleted);XCTAssertNil(document.inputFailures[.theirs])
        XCTAssertThrowsError(try document.select(.mine));XCTAssertThrowsError(try document.select(.theirs))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("output").path))
    }
    func testSelectionOnlyReturnsSideWithoutCreatingOrChangingAnyFile()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let originals=try writeInputs(root),document=try ImageSelectionDocument.capture(invocation:invocation(root,result:nil))
        for side in ImageConflictSide.allCases {
            let selected=try document.select(side)
            XCTAssertEqual(selected.selectedSide,side);XCTAssertNil(selected.output)
            XCTAssertEqual(selected.inputs[side]?.bytes,originals[side])
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:root.path)),Set(["base","mine","theirs"]))
    }
    func testChangedSourceModeOrOutputRefusesWithoutPublishing()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try writeInputs(root)
        let output=root.appendingPathComponent("output");try Data("existing".utf8).write(to:output)
        let before=try ImageSelectionDocument.capture(invocation:invocation(root))
        try Data("external".utf8).write(to:root.appendingPathComponent("mine"))
        XCTAssertThrowsError(try before.select(.base));XCTAssertEqual(try Data(contentsOf:output),Data("existing".utf8))
        let mode=try ImageSelectionDocument.capture(invocation:invocation(root))
        let mine=root.appendingPathComponent("mine"),old=try FileManager.default.attributesOfItem(atPath:mine.path)[.posixPermissions] as! NSNumber
        try FileManager.default.setAttributes([.posixPermissions:old.intValue ^ 0o100],ofItemAtPath:mine.path)
        XCTAssertThrowsError(try mode.select(.theirs))
        let replacement=try ImageSelectionDocument.capture(invocation:invocation(root))
        try Data("changed output".utf8).write(to:output)
        XCTAssertThrowsError(try replacement.select(.mine));XCTAssertEqual(try Data(contentsOf:output),Data("changed output".utf8))
    }
    func testSourceCASInsideOutputPublicationDiscardsStagedCopy()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try writeInputs(root)
        let sourceURL=root.appendingPathComponent("mine"),outputURL=root.appendingPathComponent("output")
        try Data("original output".utf8).write(to:outputURL)
        let source=try MergeToolOutputTarget(capturing:sourceURL),output=try MergeToolOutputTarget(capturing:outputURL)
        var validations=0
        XCTAssertThrowsError(try output.save(bytes:source.content.bytes,validatingInputs:{
            validations+=1
            if validations>1 {try Data("changed source".utf8).write(to:sourceURL)}
            try source.validate()
        }))
        XCTAssertGreaterThanOrEqual(validations,2,"Source witnesses must be checked again within the atomic publication boundary")
        XCTAssertEqual(try Data(contentsOf:outputURL),Data("original output".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path).filter{$0.hasPrefix(".TurtleGit")},[])
    }
    func testNestedOutputCreationAndPreCanceledCopyLeaveCorrectBytes()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let values=try writeInputs(root),document=try ImageSelectionDocument.capture(invocation:invocation(root,result:"nested/deeper/out"))
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try document.select(.mine,cancellation:token))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("nested").path))
        let saved=try document.select(.theirs)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("nested/deeper/out")),values[.theirs])
        XCTAssertEqual(saved.output?.content.bytes,values[.theirs])
    }
    func testOwnSamePathWritesAdvanceCASButRetainOriginalSelections()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let values=try writeInputs(root),document=try ImageSelectionDocument.capture(invocation:invocation(root,result:"mine"))
        let first=try document.select(.theirs)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("mine")),values[.theirs]);XCTAssertEqual(first.selectionBytes(.mine),values[.mine])
        let second=try first.select(.mine)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("mine")),values[.mine]);XCTAssertEqual(second.selectedSide,.mine)
        try Data("external".utf8).write(to:root.appendingPathComponent("mine"))
        XCTAssertThrowsError(try second.select(.base))
        XCTAssertThrowsError(try ImageSelectionDocument.capture(invocation:invocation(root,result:"mine",extra:["--delete-inputs-on-close"])))
    }
    func testHardLinkedResultBreaksAliasWithoutChangingOriginalAndSymlinksRefuse()throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let values=try writeInputs(root),mine=root.appendingPathComponent("mine"),output=root.appendingPathComponent("output")
        try FileManager.default.linkItem(at:mine,to:output)
        let saved=try ImageSelectionDocument.capture(invocation:invocation(root)).select(.theirs)
        XCTAssertEqual(saved.output?.content.bytes,values[.theirs]);XCTAssertEqual(try Data(contentsOf:mine),values[.mine])
        try FileManager.default.removeItem(at:output);try FileManager.default.createSymbolicLink(at:output,withDestinationURL:mine)
        XCTAssertThrowsError(try ImageSelectionDocument.capture(invocation:invocation(root)))
        try FileManager.default.removeItem(at:output);try FileManager.default.removeItem(at:mine)
        try FileManager.default.createSymbolicLink(at:mine,withDestinationURL:root.appendingPathComponent("theirs"))
        let linked=try ImageSelectionDocument.capture(invocation:invocation(root))
        XCTAssertNil(linked.selectionBytes(.mine));XCTAssertNotNil(linked.inputFailures[.mine])
    }
}
