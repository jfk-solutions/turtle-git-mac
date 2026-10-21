// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class RevisionGraphExportDestinationTests: XCTestCase {
    func testSourceFilterDefaultsAndFilenameSelectedEncoders() throws {
        let root=URL(fileURLWithPath:"/private/export parent.with.dots",isDirectory:true)
        for (filter,suffix,format) in [(RevisionGraphExportFilter.pictures,"svg",RevisionGraphFormat.svg),(.graphs,"gv",.graphviz),(.allFiles,"jpg",.jpeg)] {
            let value=try RevisionGraphExportDestination(url:root.appendingPathComponent("graph 雪"),filter:filter)
            XCTAssertEqual(value.url.path,root.appendingPathComponent("graph 雪."+suffix).path);XCTAssertEqual(value.format,format)
        }
        let formats:[(String,RevisionGraphFormat)]=[("SVG",.svg),("gv",.graphviz),("DOT",.graphviz),("png",.png),("jpg",.jpeg),("JPEG",.jpeg),("bmp",.bmp),("gif",.gif),("PDF",.pdf)]
        for filter in RevisionGraphExportFilter.allCases {for (suffix,format) in formats {
            let url=root.appendingPathComponent("graph."+suffix),value=try RevisionGraphExportDestination(url:url,filter:filter)
            XCTAssertEqual(value.url,url,"Existing filename overrides selected filter");XCTAssertEqual(value.format,format)
        }}
    }

    func testUnknownAndDotfileNamesAppendJPEGSuffixWithoutLosingLiteralName() throws {
        for filter in RevisionGraphExportFilter.allCases {for filename in ["graph.unknown","graph.",".hidden","caption\n\t雪[*].custom","graph.tar.gz","graph.\u{301}"] {
            let actual=try RevisionGraphExportDestination.normalizedFilename(filename,filter:filter)
            XCTAssertEqual(Data(actual.utf8),Data((filename+".jpg").utf8))
            let destination=try RevisionGraphExportDestination(url:URL(fileURLWithPath:"/tmp").appendingPathComponent(filename),filter:filter)
            XCTAssertEqual(destination.format,.jpeg);XCTAssertEqual(Data(destination.url.lastPathComponent.utf8),Data(actual.utf8))
            XCTAssertEqual(try RevisionGraphExportDestination.normalizedFilename(actual,filter:filter),actual,"Normalization must be idempotent")
        }}
        let nfc="caf\u{e9}.unknown",nfd="cafe\u{301}.unknown"
        XCTAssertNotEqual(Data(try RevisionGraphExportDestination.normalizedFilename(nfc).utf8),Data(try RevisionGraphExportDestination.normalizedFilename(nfd).utf8))
    }

    func testUnsupportedMetafilesAndInvalidDestinationsRefuseBeforeFilesystemWork() throws {
        for filter in RevisionGraphExportFilter.allCases {for suffix in ["wmf","WMF","emf","EMF"] {
            do {_ = try RevisionGraphExportDestination(url:URL(fileURLWithPath:"/tmp/graph."+suffix),filter:filter);XCTFail("Metafile must not silently become JPEG")}
            catch RevisionGraphExportFailure.metafile {XCTAssertTrue(RevisionGraphExportFailure.metafile.localizedDescription.contains("PDF"))}
        }}
        for filename in ["",".","..","folder/name","bad\0name"] {XCTAssertThrowsError(try RevisionGraphExportDestination.normalizedFilename(filename))}
        XCTAssertThrowsError(try RevisionGraphExportDestination(url:URL(string:"https://example.invalid/graph.svg")!))
        XCTAssertThrowsError(try RevisionGraphExportDestination(url:URL(fileURLWithPath:"/tmp",isDirectory:true)))
    }

    func testCommandLineCapturesNormalizedOutputBeforeGrantAndPreservesOtherCommandOutputs() throws {
        func parse(_ filename:String)throws->PrimaryCommandInvocation {
            let invocation = try PrimaryCommandInvocation.parse(arguments:["--command=revisiongraph","--path=repository","--output="+filename],currentDirectory:"/private/working")
            return try XCTUnwrap(invocation)
        }
        for (filename,normalized,format) in [("graph","graph.jpg",RevisionGraphFormat.jpeg),("unknown.type","unknown.type.jpg",.jpeg),("picture.SVG","picture.SVG",.svg),("native.dot","native.dot",.graphviz),("vector.pdf","vector.pdf",.pdf),(".hidden",".hidden.jpg",.jpeg)] {
            let invocation=try parse(filename)
            XCTAssertEqual(invocation.outputFile?.path,"/private/working/"+normalized);XCTAssertEqual(invocation.graphOutputFormat,format)
            XCTAssertEqual(invocation.selecting([URL(fileURLWithPath:"/other/repository")]).outputFile,invocation.outputFile)
        }
        XCTAssertThrowsError(try parse("graph.emf"));XCTAssertThrowsError(try parse("graph.wmf"))
        let cat=try XCTUnwrap(PrimaryCommandInvocation.parse(arguments:["--command=cat","--revision=HEAD","--savepath=raw.unknown"],currentDirectory:"/private/working"))
        XCTAssertEqual(cat.outputFile?.path,"/private/working/raw.unknown");XCTAssertNil(cat.graphOutputFormat)
        let noOutput=try XCTUnwrap(PrimaryCommandInvocation.parse(arguments:["--command=revisiongraph","--output="],currentDirectory:"/private/working"))
        XCTAssertNil(noOutput.outputFile);XCTAssertNil(noOutput.graphOutputFormat)
    }
}
