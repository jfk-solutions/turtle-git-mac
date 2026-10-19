import XCTest
@testable import TurtleGitCore

final class PresentationComparisonTests: XCTestCase {
    private func slides(_ values: [(String?,String,String,String?)]) -> [PresentationSlide] {
        values.enumerated().map { PresentationSlide(pageIndex:$0.offset,stableID:$0.element.0,text:$0.element.1,notes:$0.element.2,visualFingerprint:$0.element.3) }
    }
    private func report(_ a:[PresentationSlide],_ b:[PresentationSlide]) throws -> PresentationComparisonReport {
        try .init(base:a,destination:b,cancellation:.init())
    }
    private func assertCoverage(_ value:PresentationComparisonReport,_ a:Int,_ b:Int,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertEqual(value.rows.compactMap(\.base).map(\.pageIndex).sorted(),Array(0..<a),file:file,line:line)
        XCTAssertEqual(value.rows.compactMap(\.destination).map(\.pageIndex).sorted(),Array(0..<b),file:file,line:line)
    }
    func testCapturedInputsArePrivateReadOnlyAndOutputsDistinct() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let a=ComparisonFileContent(path:"old/same 雪.PPTM",revision:.revision("snapshot"),bytes:Data([0,255,10]),mode:"120000")
        let b=ComparisonFileContent(path:"new/same 雪.PPTM",revision:.workingTree,bytes:Data([1,254,13]),mode:"100644")
        let value=try PresentationComparisonPreview.prepare(.init(base:a,destination:b),in:root,cancellation:.init())
        XCTAssertEqual(try Data(contentsOf:value.base),a.bytes); XCTAssertEqual(try Data(contentsOf:value.destination),b.bytes)
        XCTAssertEqual(value.base.lastPathComponent,"same 雪.PPTM"); XCTAssertNotEqual(value.base,value.destination)
        for url in [value.base,value.destination] { XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o444) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:value.directory.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        let outputs=[value.basePDF,value.destinationPDF,value.baseManifest,value.destinationManifest]
        XCTAssertEqual(Set(outputs).count,4); XCTAssertTrue(outputs.allSatisfy { $0.deletingLastPathComponent()==value.directory && !FileManager.default.fileExists(atPath:$0.path) })
        value.discard(); value.discard(); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
    func testPreparationRejectsDeletedUnsupportedAndCancelledWithoutArtifacts() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func content(_ path:String,_ deleted:Bool=false)->ComparisonFileContent { .init(path:path,revision:.workingTree,bytes:Data(),mode:"100644",isDeleted:deleted) }
        for pair in [(content("a.pptx",true),content("b.pptx")),(content("a.pptx"),content("b.pptx",true)),(content("a.zip"),content("b.pptx"))] {
            XCTAssertThrowsError(try PresentationComparisonPreview.prepare(.init(base:pair.0,destination:pair.1),in:root,cancellation:.init()))
        }
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try PresentationComparisonPreview.prepare(.init(base:content("a.ppt"),destination:content("b.pptm")),in:root,cancellation:token))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
    func testStableIdentityPreservesReorderedModifiedTextNotesAndVisuals() throws {
        let a=slides([("A","a","","1"),("B","b","n","2"),("C","c","","3")])
        let b=slides([("C","c","","3"),("A","a changed","","1"),("B","b","changed","4")])
        let value=try report(a,b); assertCoverage(value,3,3)
        XCTAssertEqual(value.rows.map(\.base!.stableID),["C","A","B"])
        XCTAssertEqual(value.rows.map(\.change),[.unchanged,.modified,.modified])
        XCTAssertEqual(value.rows.filter(\.isMoved).count,1)
    }
    func testInsertionsAndDeletionsDoNotMarkRemainingSlidesMoved() throws {
        let a=slides([("A","a","","1"),("B","b","","2"),("C","c","","3")])
        let b=slides([("X","x","","4"),("A","a","","1"),("C","c","","3")])
        // Distinct explicit identities remain deletion/insertion rather than
        // being mislabeled a positional modification.
        let value=try report(a,b); assertCoverage(value,3,3)
        XCTAssertEqual(value.rows.filter { $0.change == .added }.count,1)
        XCTAssertEqual(value.rows.filter { $0.change == .deleted }.count,1)
        XCTAssertFalse(value.rows.contains(where: \.isMoved))
        let added=try report(a,slides([("X","x","","4"),("A","a","","1"),("B","b","","2"),("C","c","","3")]))
        assertCoverage(added,3,4); XCTAssertEqual(added.rows.filter { $0.change == .added }.count,1); XCTAssertFalse(added.rows.contains(where: \.isMoved))
        let deleted=try report(a,slides([("A","a","","1"),("C","c","","3")]))
        assertCoverage(deleted,3,2); XCTAssertEqual(deleted.rows.filter { $0.change == .deleted }.count,1); XCTAssertFalse(deleted.rows.contains(where: \.isMoved))
    }
    func testVisualMatchesReorderSlidesWithoutIDsAndRetainNotesChanges() throws {
        let a=slides([(nil,"a","","red"),(nil,"b","","blue")])
        let b=slides([(nil,"b","changed notes","blue"),(nil,"a","","red")])
        let value=try report(a,b); assertCoverage(value,2,2)
        XCTAssertEqual(value.rows.compactMap(\.base).map(\.pageIndex),[1,0])
        XCTAssertEqual(value.rows.map(\.change),[.modified,.unchanged]); XCTAssertEqual(value.rows.filter(\.isMoved).count,1)
    }
    func testRepeatedBlankSlidesAndEmptyDecksPreserveEveryOccurrence() throws {
        for count in [0,1,3,512] {
            let a=slides(Array(repeating:(nil,"","",nil),count:count))
            let value=try report(a,a); assertCoverage(value,count,count)
            XCTAssertTrue(value.rows.allSatisfy { $0.change == .unchanged && !$0.isMoved })
        }
        let a=slides([(nil,"a","",nil),(nil,"a","",nil)])
        assertCoverage(try report(a,[]),2,0); assertCoverage(try report([],a),0,2)
    }
    func testManifestRoundTripValidationAndCancellationAreBounded() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        let a=slides([("1","literal\n雪\0","notes","abc")])
        try PresentationSlideManifest(slides:a).write(to:url,cancellation:.init())
        XCTAssertEqual(try PresentationSlideManifest.read(from:url,cancellation:.init()).slides,a)
        XCTAssertThrowsError(try PresentationSlideManifest(slides:a).write(to:url,cancellation:.init()))
        for bad in [[PresentationSlide(pageIndex:1,text:"",notes:"")],slides([("1","","",nil),("1","","",nil)]),slides([(nil,"","","")]),slides(Array(repeating:(nil,"","",nil),count:513))] {
            XCTAssertThrowsError(try report(bad,[]))
        }
        let token=OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try PresentationComparisonReport(base:a,destination:a,cancellation:token))
        XCTAssertThrowsError(try PresentationSlideManifest.read(from:url,cancellation:token))
        try Data("{\"version\":2,\"slides\":[]}".utf8).write(to:url)
        XCTAssertThrowsError(try PresentationSlideManifest.read(from:url,cancellation:.init()))
    }
    func testCanonicalUnicodeTextIsComparedLiterally() throws {
        let value=try report(slides([("1","é","",nil)]),slides([("1","e\u{301}","",nil)]))
        XCTAssertEqual(value.rows.first?.change,.modified)
    }
    func testBundledPowerPointAssociationsPreserveCustomPrograms() throws {
        let suite="TurtleGit.PresentationTests."+UUID().uuidString, defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        var value=DiffToolPreferences.load(from:defaults)
        for ext in [".ppt",".pptx",".pptm"] {
            XCTAssertEqual(try value.selected(base:"a"+ext,destination:"b"+ext.uppercased())?.builtIn,.powerPointPresentation)
            XCTAssertNil(try value.selected(base:"a"+ext,destination:"b"+ext,alternate:true))
        }
        var custom=DiffToolAssociation();custom.pattern=".pptx";custom.program.applicationPath="/Applications/Other.app"
        value.associations.removeAll { $0.pattern == ".pptx" };value.associations.append(custom)
        try value.save(to:defaults)
        XCTAssertEqual(try DiffToolPreferences.load(from:defaults).selected(base:"a.pptx",destination:"b.pptx")?.applicationPath,custom.program.applicationPath)
        value.restoreBundledAssociations();XCTAssertEqual(value.associations.first { $0.pattern == ".pptx" }?.id,custom.id)
    }
}
