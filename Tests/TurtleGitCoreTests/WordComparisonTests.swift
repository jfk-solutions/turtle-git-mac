import XCTest
@testable import TurtleGitCore

final class WordComparisonTests: XCTestCase {
    private func document(absent: Bool = false) -> FileComparisonDocument {
        .init(base:.init(path:"folder/same \" 雪.docx",revision:.revision("captured"),bytes:Data([0,0xff,1,10]),mode:"100644",isDeleted:absent),destination:.init(path:"other/same \" 雪.docx",revision:.workingTree,bytes:Data([2,0xfe,3,13]),mode:"100755"))
    }
    func testExactPrivateInputsNamesPermissionsAndIndependentSides() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let original=document(), preview=try WordComparisonPreview.prepare(original,in:root,cancellation:.init())
        XCTAssertEqual(preview.base.lastPathComponent,"same \" 雪.docx"); XCTAssertEqual(preview.destination.lastPathComponent,preview.base.lastPathComponent)
        XCTAssertNotEqual(preview.base,preview.destination)
        XCTAssertEqual(try Data(contentsOf:preview.base),original.base.bytes); XCTAssertEqual(try Data(contentsOf:preview.destination),original.destination.bytes)
        for url in [preview.base,preview.destination] { XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o444) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:preview.directory.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        preview.discard(); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
    func testCancelledAndAbsentPreparationLeavesNoInputs() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let token=OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try WordComparisonPreview.prepare(document(),in:root,cancellation:token))
        XCTAssertThrowsError(try WordComparisonPreview.prepare(document(absent:true),in:root,cancellation:.init()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
    func testWordAssociationsShiftExistingSettingsAndMergeSelection() throws {
        let suite="TurtleGit.WordTests."+UUID().uuidString, defaults=UserDefaults(suiteName:suite)!; defer { defaults.removePersistentDomain(forName:suite) }
        var value=DiffToolPreferences.load(from:defaults)
        for ext in BuiltInDiffTool.wordDocument.extensions {
            XCTAssertEqual(try value.selected(base:"base"+ext,destination:"new"+ext.uppercased())?.builtIn,.wordDocument)
            XCTAssertNil(try value.selected(base:"base"+ext,destination:"new"+ext,alternate:true))
        }
        var custom=DiffToolAssociation(); custom.pattern=".docx"; custom.program.applicationPath="/Applications/Other.app"
        value.associations.removeAll { $0.pattern==".docx" }; value.associations.append(custom)
        try value.save(to:defaults); XCTAssertEqual(try DiffToolPreferences.load(from:defaults).selected(base:"a.docx",destination:"b.docx")?.applicationPath,custom.program.applicationPath)
        value.restoreBundledAssociations(); XCTAssertEqual(value.associations.first { $0.pattern==".docx" }?.id,custom.id)
        var merge=MergeToolPreferences(); var program=DiffToolProgram(); program.enabled=true; program.builtIn = .wordDocument; merge.program=program
        XCTAssertTrue(merge.valid); XCTAssertEqual(try merge.selected(path:"a.docx")?.builtIn,.wordDocument)
    }
    func testPermissionAndUncertainDispatchFailuresDistinguishRetention() {
        let denied=WordComparisonFailure.automation(-1743,"denied",possiblyOpened:false)
        XCTAssertFalse(denied.possiblyOpened); XCTAssertTrue(denied.localizedDescription.contains("Privacy & Security"))
        XCTAssertFalse(WordComparisonFailure.application.possiblyOpened)
        XCTAssertTrue(WordComparisonFailure.automation(-1712,"timeout",possiblyOpened:true).possiblyOpened)
    }
}
