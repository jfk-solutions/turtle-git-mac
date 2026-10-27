// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

/// Preparation only: these checks never launch or automate Office or a notebook
/// application. Captured bytes must reach distinct, safe, read-only inputs.
final class RawComparisonPreviewTests:XCTestCase {
    private let firstOID=String(repeating:"a",count:40),secondOID=String(repeating:"b",count:40)
    private func document(_ suffix:String,missingOID:Bool=false)throws->FileComparisonDocument {
        let first=try RepositoryBrowserGitPath(rawData:Data([0xff])+Data((" source."+suffix).utf8)).key
        // A valid leaf beneath a raw directory is still a raw full tree path.
        let second=try RepositoryBrowserGitPath(rawData:Data([0xfe,47])+Data(("source."+suffix).utf8)).key
        return FileComparisonDocument(base:.init(path:first,revision:.revision("captured-first"),bytes:Data([0,255,1,10]),mode:"100644",objectID:missingOID ? nil:firstOID),destination:.init(path:second,revision:.revision("captured-second"),bytes:Data([2,254,13,10]),mode:"100755",objectID:missingOID ? nil:secondOID))
    }
    private func root()throws->URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("raw preview QA-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return url
    }
    private func check(_ url:URL,bytes:Data,in directory:URL)throws {
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path+"/"))
        XCTAssertFalse(url.path.utf8.contains(0));XCTAssertFalse(url.lastPathComponent.contains("⟦"))
        XCTAssertEqual(try Data(contentsOf:url),bytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o444)
    }
    func testOfficePreviewsRetainOriginalExtensionBytesAndSeparateImmutableSides()throws {
        let folder=try root();defer{try? FileManager.default.removeItem(at:folder)}
        let wordDocument=try document("docx"),word=try WordComparisonPreview.prepare(wordDocument,in:folder,cancellation:.init())
        XCTAssertEqual(word.base.lastPathComponent,"Git-blob-"+firstOID+".docx")
        XCTAssertEqual(word.destination.lastPathComponent,"Git-blob-"+secondOID+".docx")
        try check(word.base,bytes:wordDocument.base.bytes,in:word.directory);try check(word.destination,bytes:wordDocument.destination.bytes,in:word.directory)
        XCTAssertNotEqual(word.base,word.destination);word.discard()
        let excelDocument=try document("xlsx"),excel=try ExcelComparisonPreview.prepare(excelDocument,in:folder,fast:true,cancellation:.init())
        XCTAssertEqual(excel.base.lastPathComponent,"base-Git-blob-"+firstOID+".xlsx")
        XCTAssertEqual(excel.destination.lastPathComponent,"new-Git-blob-"+secondOID+".xlsx");XCTAssertTrue(excel.fast)
        try check(excel.base,bytes:excelDocument.base.bytes,in:excel.directory);try check(excel.destination,bytes:excelDocument.destination.bytes,in:excel.directory);excel.discard()
        let slides=try document("PpT"),presentation=try PresentationComparisonPreview.prepare(slides,in:folder,cancellation:.init())
        XCTAssertEqual(presentation.base.pathExtension,"PpT");XCTAssertEqual(presentation.destination.pathExtension,"PpT")
        XCTAssertEqual(presentation.basePackage.lastPathComponent,"base-normalized.pptm")
        XCTAssertEqual(presentation.destinationPackage.lastPathComponent,"new-normalized.pptm")
        try check(presentation.base,bytes:slides.base.bytes,in:presentation.directory);try check(presentation.destination,bytes:slides.destination.bytes,in:presentation.directory);presentation.discard()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:folder.path).isEmpty)
    }
    func testNotebookSourceReferencesOnlySafePrivateLeavesAndBinaryReportEscapesLabels()throws {
        let folder=try root();defer{try? FileManager.default.removeItem(at:folder)}
        let original=try document("nb"),preview=try NotebookComparisonPreview.prepare(original,in:folder)
        try check(preview.base,bytes:original.base.bytes,in:preview.directory);try check(preview.destination,bytes:original.destination.bytes,in:preview.directory)
        XCTAssertEqual(preview.base.lastPathComponent,"Git-blob-"+firstOID+".nb")
        let source=try String(contentsOf:preview.notebook,encoding:.utf8)
        XCTAssertTrue(source.contains("Git-blob-"+firstOID+".nb"));XCTAssertTrue(source.contains("Git-blob-"+secondOID+".nb"))
        XCTAssertFalse(source.contains("TurtleGitBrowserPath"));XCTAssertFalse(source.contains("⟦"))
        preview.discard()
        let report=try BinaryComparisonReport(original)
        XCTAssertFalse(report.text.utf8.contains(0));XCTAssertFalse(report.text.contains("TurtleGitBrowserPath"))
        XCTAssertTrue(report.text.contains(RepositoryBrowserGitPath.display(key:original.base.path)))
        XCTAssertTrue(report.text.contains(RepositoryBrowserGitPath.display(key:original.destination.path)))
        let ordinary=FileComparisonDocument(base:.init(path:"/private/ordinary old.dll",revision:.workingTree,bytes:Data([1]),mode:"100644"),destination:.init(path:"/private/ordinary new.dll",revision:.workingTree,bytes:Data([2]),mode:"100644"))
        XCTAssertTrue(try BinaryComparisonReport(ordinary).text.contains("/private/ordinary old.dll"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:folder.path).isEmpty)
    }
    func testAbsentHistoricalSidesHaveExplicitNamesWithoutBorrowingPeerObjectIdentity()throws {
        let folder=try root();defer{try? FileManager.default.removeItem(at:folder)}
        let key=try RepositoryBrowserGitPath(rawData:Data([0xff])).key
        let empty=ComparisonFileContent(path:key,revision:.emptyTree,bytes:Data(),mode:nil)
        let wordInput=FileComparisonDocument(base:empty,destination:try document("docx").destination)
        let word=try WordComparisonPreview.prepare(wordInput,in:folder,cancellation:.init())
        XCTAssertEqual(word.base.lastPathComponent,"base-absent.docx");try check(word.base,bytes:Data(),in:word.directory);word.discard()
        let excelInput=FileComparisonDocument(base:empty,destination:try document("xls").destination)
        let excel=try ExcelComparisonPreview.prepare(excelInput,in:folder,fast:false,cancellation:.init())
        XCTAssertEqual(excel.base.lastPathComponent,"base-base-absent.xls");try check(excel.base,bytes:Data(),in:excel.directory);excel.discard()
        let presentationInput=FileComparisonDocument(base:empty,destination:try document("pptm").destination)
        let slides=try PresentationComparisonPreview.prepare(presentationInput,in:folder,cancellation:.init())
        XCTAssertEqual(slides.base.lastPathComponent,"base-absent.pptm");try check(slides.base,bytes:Data(),in:slides.directory);slides.discard()
        let notebookInput=FileComparisonDocument(base:empty,destination:try document("nb").destination)
        let notebook=try NotebookComparisonPreview.prepare(notebookInput,in:folder)
        XCTAssertEqual(notebook.base.lastPathComponent,"base-absent.nb");try check(notebook.base,bytes:Data(),in:notebook.directory);notebook.discard()
        let nonempty=ComparisonFileContent(path:key,revision:.revision("captured"),bytes:Data([1]),mode:nil)
        XCTAssertThrowsError(try ComparisonPreviewInputName.leaf(for:nonempty,other:wordInput.destination,side:"base",fallbackExtension:"docx"))
        XCTAssertThrowsError(try ComparisonPreviewInputName.leaf(for:empty,other:wordInput.destination,side:"../escape",fallbackExtension:"docx"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:folder.path).isEmpty)
    }

    func testMissingObjectProvenanceMalformedFormatAndCancellationLeaveNoPrivateOutputs()throws {
        let folder=try root();defer{try? FileManager.default.removeItem(at:folder)}
        XCTAssertThrowsError(try WordComparisonPreview.prepare(document("docx",missingOID:true),in:folder,cancellation:.init()))
        XCTAssertThrowsError(try ExcelComparisonPreview.prepare(document("xlsx",missingOID:true),in:folder,fast:false,cancellation:.init()))
        XCTAssertThrowsError(try PresentationComparisonPreview.prepare(document("pptx",missingOID:true),in:folder,cancellation:.init()))
        XCTAssertThrowsError(try NotebookComparisonPreview.prepare(document("nb",missingOID:true),in:folder))
        let malformed=try RepositoryBrowserGitPath(rawData:Data([0xff,46,0xfe])).key
        let invalid=ComparisonFileContent(path:malformed,revision:.revision("captured"),bytes:Data(),mode:"100644",objectID:firstOID)
        XCTAssertThrowsError(try PresentationComparisonPreview.prepare(.init(base:invalid,destination:invalid),in:folder,cancellation:.init()))
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try WordComparisonPreview.prepare(document("docx"),in:folder,cancellation:token))
        XCTAssertThrowsError(try ExcelComparisonPreview.prepare(document("xlsx"),in:folder,fast:false,cancellation:token))
        XCTAssertThrowsError(try PresentationComparisonPreview.prepare(document("pptx"),in:folder,cancellation:token))
        XCTAssertThrowsError(try NotebookComparisonPreview.prepare(document("nb"),in:folder,cancellation:token))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:folder.path).isEmpty)
    }
}
