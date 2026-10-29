import XCTest
@testable import TurtleGitCore

final class GitBlameDocumentTests:XCTestCase {
    private let revision=String(repeating:"a",count:40)
    private func document(_ contents:Data,path:String="file.txt",mutate:((inout Data)->Void)? = nil)throws->GitBlameDocument {
        var parts=contents.split(separator:UInt8(10),omittingEmptySubsequences:false).map{Data($0)}
        if contents.isEmpty || contents.last==10 {parts.removeLast()}
        var wire=Data()
        for (index,part) in parts.enumerated() {
            wire.append(Data("\(revision) \(index+7) \(index+1)\nauthor Jochen Kühner\nauthor-mail <a@example.invalid>\nauthor-time 1700000000\nauthor-tz +0130\nsummary Captured subject\nboundary\nfilename \(path)\n\t".utf8))
            wire.append(part);wire.append(10)
        }
        mutate?(&wire)
        return try GitBlameDocument(revision:revision,path:path,contents:contents,porcelain:wire)
    }
    func testFailedAutomaticRetainsLegacyBytesAndAttributionForMultipleProjections()throws {
        let bytes=Data([0x63,0x61,0x66,0xe9,0x20,0x80,0x0d,0x0a]),doc=try document(bytes)
        XCTAssertThrowsError(try doc.project())
        let cp=try XCTUnwrap(GitBlameEncoding.available.first{$0.windowsCodePage==1252})
        let snapshot=try doc.project(encoding:cp)
        XCTAssertEqual(snapshot.contents,bytes);XCTAssertEqual(snapshot.lines.first?.source,"café €\r")
        let line=try XCTUnwrap(snapshot.lines.first)
        XCTAssertEqual(line.hash,revision);XCTAssertEqual(line.originalLine,7);XCTAssertEqual(line.number,1)
        XCTAssertEqual(line.author,"Jochen Kühner");XCTAssertEqual(line.email,"a@example.invalid")
        XCTAssertEqual(line.summary,"Captured subject");XCTAssertEqual(line.timezone,"+0130");XCTAssertTrue(line.boundary)
        XCTAssertEqual(line.sourceBytes,Data(bytes.dropLast()));XCTAssertEqual(line.filename,"file.txt")
        XCTAssertThrowsError(try doc.project(encoding:.utf8))
        XCTAssertEqual(try doc.project(encoding:cp).lines.map(\.source),snapshot.lines.map(\.source))
        XCTAssertEqual(doc.annotationSnapshot.lines.map(\.source),[""])
        XCTAssertEqual(doc.annotationSnapshot.lines.map(\.sourceBytes),snapshot.lines.map(\.sourceBytes))
        XCTAssertEqual(try GitBlameDocument(snapshot:snapshot).project(encoding:cp).lines.map(\.source),snapshot.lines.map(\.source))
    }
    func testUTF16ProjectionRetainsByteLineBoundariesBOMAndFinalLine()throws {
        for (codec,encoding,bom) in [(GitBlameEncoding.utf16LE,String.Encoding.utf16LittleEndian,Data([0xff,0xfe])),(.utf16BE,.utf16BigEndian,Data([0xfe,0xff]))] {
            var bytes=bom;bytes.append(try XCTUnwrap("雪🐢\r\nnext".data(using:encoding)))
            let doc=try document(bytes),snapshot=try doc.project()
            XCTAssertEqual(snapshot.encoding,codec);XCTAssertEqual(snapshot.lines.map(\.source),["雪🐢\r","next"])
            XCTAssertEqual(snapshot.contents,bytes)
            XCTAssertEqual(try GitBlameDocument(snapshot:snapshot).project(encoding:codec).lines.map(\.sourceBytes),snapshot.lines.map(\.sourceBytes))
        }
        let utf8=try document(Data("\u{feff}a\n\nlast".utf8))
        XCTAssertEqual(try utf8.project().lines.map(\.source),["\u{feff}a","","last"])
        XCTAssertTrue(try document(Data()).project().lines.isEmpty)
    }
    func testStatefulLegacyProjectionDecodesWholePinnedSource()throws {
        guard let codec=GitBlameEncoding.available.first(where:{$0.windowsCodePage==50220 || $0.windowsCodePage==50221 || $0.windowsCodePage==50222}),
              let bytes="日本\n語".data(using:String.Encoding(rawValue:codec.id)) else {throw XCTSkip("Host provides no ISO-2022-JP encoder")}
        let snapshot=try document(bytes).project(encoding:codec)
        XCTAssertEqual(snapshot.lines.map(\.source),["日本","語"])
        XCTAssertEqual(snapshot.contents,bytes)
        XCTAssertEqual(try GitBlameDocument(snapshot:snapshot).project(encoding:codec).lines.map(\.source),snapshot.lines.map(\.source))
    }
    func testRawValidationRejectsFramingSourceMismatchAndMalformedMetadata()throws {
        XCTAssertThrowsError(try document(Data("a\n".utf8),mutate:{$0.removeLast()}))
        XCTAssertThrowsError(try document(Data("a\n".utf8),mutate:{wire in wire[wire.count-2]=98}))
        XCTAssertThrowsError(try document(Data("a\n".utf8),mutate:{wire in wire=Data(String(decoding:wire,as:UTF8.self).replacingOccurrences(of:"author-tz +0130",with:"author-tz +2460").utf8)}))
        XCTAssertThrowsError(try document(Data("a\n".utf8),mutate:{wire in wire=Data(String(decoding:wire,as:UTF8.self).replacingOccurrences(of:" 7 1\n",with:" 7 2\n").utf8)}))
        // Valid raw attribution is retained even when its source is not safe text.
        let binary=try document(Data([0,1,2]));XCTAssertThrowsError(try binary.project())
        let ambiguous=try document(Data([0xff,0xfe,0x0a,0x01]));XCTAssertThrowsError(try ambiguous.project())
    }
    func testProjectionCancellationAndSnapshotValidationDoNotChangeDocument()throws {
        let doc=try document(Data("one\ntwo\n".utf8)),snapshot=try doc.project()
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try doc.project(encoding:.utf8,cancellation:token))
        XCTAssertThrowsError(try GitBlameDocument(revision:revision,path:"file.txt",contents:Data(),porcelain:Data(),cancellation:token))
        let wrong=GitBlameSnapshot(revision:snapshot.revision,path:snapshot.path,contents:Data("other\n".utf8),encoding:snapshot.encoding,lines:snapshot.lines)
        XCTAssertThrowsError(try GitBlameDocument(snapshot:wrong))
        XCTAssertEqual(try doc.project().lines.map(\.source),["one","two"])
    }
    func testRealGitDocumentRecoversLegacyWithoutRepositoryRereads()async throws {
        let (root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let bytes=Data([0x72,0xe9,0x73,0x75,0x6c,0x75,0x0a])
        try bytes.write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"legacy source")
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let doc=try await repo.blameDocument(path:path)
        XCTAssertThrowsError(try doc.project())
        // No executable/repository is involved after capture: remove the source
        // and object namespace, then prove interpretation uses retained bytes.
        let metadata=root.appendingPathComponent(".git"),held=root.appendingPathComponent("held-git")
        try FileManager.default.moveItem(at:metadata,to:held)
        defer{try? FileManager.default.moveItem(at:held,to:metadata)}
        try Data("independent working edit\n".utf8).write(to:root.appendingPathComponent(path))
        let cp=try XCTUnwrap(GitBlameEncoding.available.first{$0.windowsCodePage==1252})
        let snapshot=try doc.project(encoding:cp)
        XCTAssertEqual(snapshot.lines.map(\.source),["résulu"])
        XCTAssertEqual(snapshot.contents,bytes);XCTAssertEqual(snapshot.revision,doc.revision)
        XCTAssertEqual(try Data(contentsOf:held.appendingPathComponent("index")),index)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(path),encoding:.utf8),"independent working edit\n")
    }
}
