import XCTest
@testable import TurtleGitCore
final class ExcelComparisonTests:XCTestCase {
    private var document:FileComparisonDocument {
        .init(base:.init(path:"folder/same \" 雪.xlsx",revision:.workingTree,bytes:Data([0,255,1]),mode:"100644"),destination:.init(path:"other/same \" 雪.xlsx",revision:.revision("snapshot"),bytes:Data([0,254,2]),mode:"100644"))
    }
    func testExactPrivateWorkbookCopiesDistinctNamesAndModes() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        for fast in [false,true] {
            let preview=try ExcelComparisonPreview.prepare(document,in:root,fast:fast,cancellation:.init())
            XCTAssertEqual(preview.fast,fast);XCTAssertNotEqual(preview.base.lastPathComponent,preview.destination.lastPathComponent)
            XCTAssertTrue(preview.base.lastPathComponent.contains("same \" 雪.xlsx"));XCTAssertEqual(try Data(contentsOf:preview.base),document.base.bytes);XCTAssertEqual(try Data(contentsOf:preview.destination),document.destination.bytes)
            for file in [preview.base,preview.destination] { XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o444) }
            preview.discard();XCTAssertFalse(FileManager.default.fileExists(atPath:preview.directory.path))
        }
    }
    func testCancellationAndAbsentWorkbookLeaveNoCopies() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let token=OperationCancellation();token.cancel();XCTAssertThrowsError(try ExcelComparisonPreview.prepare(document,in:root,fast:false,cancellation:token))
        let absent=ComparisonFileContent(path:"absent.xlsx",revision:.workingTree,bytes:Data(),mode:nil,isDeleted:true)
        XCTAssertThrowsError(try ExcelComparisonPreview.prepare(.init(base:absent,destination:document.destination),in:root,fast:true,cancellation:.init()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
    func testFiveDefaultFormatsFastChoiceAndMergeRefusal() throws {
        let suite="TurtleGit.ExcelTests."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;defer{prefs.removePersistentDomain(forName:suite)}
        var settings=DiffToolPreferences.load(from:prefs)
        for ext in BuiltInDiffTool.excelWorkbook.extensions { XCTAssertEqual(try settings.selected(base:"a"+ext,destination:"b"+ext.uppercased())?.builtIn,.excelWorkbook);XCTAssertNil(try settings.selected(base:"a"+ext,destination:"b"+ext,alternate:true)) }
        XCTAssertTrue(BuiltInDiffTool.excelWorkbookFast.extensions.isEmpty)
        let index=settings.associations.firstIndex{$0.pattern==".xlsx"}!;settings.associations[index].program.builtIn = .excelWorkbookFast;let id=settings.associations[index].id
        try settings.save(to:prefs);XCTAssertEqual(try DiffToolPreferences.load(from:prefs).selected(base:"a.xlsx",destination:"b.xlsx")?.builtIn,.excelWorkbookFast)
        settings.restoreBundledAssociations();XCTAssertEqual(settings.associations.first{$0.pattern==".xlsx"}?.id,id)
        for kind in [BuiltInDiffTool.excelWorkbook,.excelWorkbookFast] { var merge=MergeToolPreferences();merge.program.enabled=true;merge.program.builtIn=kind;XCTAssertFalse(merge.valid);XCTAssertThrowsError(try merge.selected(path:"a.xlsx")) }
    }
    func testWarningsCapAndPermissionReceiptSemantics() {
        XCTAssertTrue(ExcelComparisonOutcome().warningText.isEmpty)
        let outcome=ExcelComparisonOutcome(warnings:(1...13).map{"warning \($0)"})
        XCTAssertTrue(outcome.warningText.contains("[10] warning 10"));XCTAssertFalse(outcome.warningText.contains("[11]"));XCTAssertTrue(outcome.warningText.hasSuffix("And more 3 messages"))
        XCTAssertFalse(ExcelComparisonFailure.application.possiblyOpened);XCTAssertFalse(ExcelComparisonFailure.automation(-1743,"denied",possiblyOpened:false).possiblyOpened)
        XCTAssertTrue(ExcelComparisonFailure.automation(-1712,"timeout",possiblyOpened:true).possiblyOpened);XCTAssertTrue(ExcelComparisonFailure.automation(-1743,"denied",possiblyOpened:false).localizedDescription.contains("Automation"))
    }
}
