import XCTest
@testable import TurtleGitCore
final class WordMergeTests:XCTestCase {
    private func input(_ root:URL)->ExternalMergeInputs {
        .init(entry:.init(path:"file \" 雪.docx",stages:[.init(number:1,mode:"100644",object:"base"),.init(number:2,mode:"100644",object:"mine"),.init(number:3,mode:"100644",object:"theirs")]),base:Data([1,0,255]),mine:Data([2,0,254]),theirs:Data([3,0,253]),result:root.appendingPathComponent("file \" 雪.docx"))
    }
    func testEditablePrivateStagesAndOriginalResultAreIndependent() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let original=input(root); try Data("working result".utf8).write(to:original.result)
        let preview=try WordMergePreview.prepare(original,in:root,cancellation:.init())
        XCTAssertEqual(preview.result,original.result)
        for (url,bytes,side) in [(preview.base,original.base,"base"),(preview.mine,original.mine,"mine"),(preview.theirs,original.theirs,"theirs")] {
            XCTAssertEqual(try Data(contentsOf:url),bytes); XCTAssertTrue(url.lastPathComponent.hasPrefix(side+"-"))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        }
        try Data("edited private mine".utf8).write(to:preview.mine)
        XCTAssertEqual(try Data(contentsOf:original.result),Data("working result".utf8))
        preview.discard(); XCTAssertFalse(FileManager.default.fileExists(atPath:preview.directory.path)); XCTAssertTrue(FileManager.default.fileExists(atPath:original.result.path))
    }
    func testCancellationLeavesNoMergeDirectory() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let token=OperationCancellation();token.cancel();XCTAssertThrowsError(try WordMergePreview.prepare(input(root),in:root,cancellation:token))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
    func testMergeDefaultsPreserveSavedChoicesAndRestoreIdentity() throws {
        let suite="TurtleGit.WordMerge."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;defer{prefs.removePersistentDomain(forName:suite)}
        var value=MergeToolPreferences.load(from:prefs)
        XCTAssertEqual(value.associations.map(\.pattern),[".doc",".docx",".docm"])
        XCTAssertEqual(try value.selected(path:"A.DOCX")?.builtIn,.wordDocument);XCTAssertNil(try value.selected(path:"a.docx",alternate:true))
        XCTAssertFalse(value.supportsTrustedExit)
        let id=value.associations[1].id;value.associations[1].program.enabled=false;try value.save(to:prefs)
        XCTAssertNil(try MergeToolPreferences.load(from:prefs).selected(path:"a.docx"))
        XCTAssertEqual(try value.selected(path:"a.docx",alternate:true)?.builtIn,.wordDocument)
        var other=DiffToolAssociation();other.pattern=".txt";other.program.enabled=false;value.associations.append(other)
        value.restoreBundledAssociations();XCTAssertEqual(value.associations.first{$0.pattern==".docx"}?.id,id);XCTAssertTrue(value.associations.contains(other))
        let saved=MergeToolPreferences();try saved.save(to:prefs);XCTAssertTrue(MergeToolPreferences.load(from:prefs).associations.isEmpty)
    }
    func testDiffOnlyAdaptersRemainInvalidForMerging() throws {
        for kind in [BuiltInDiffTool.zipInventory,.binaryReport,.mathematicaNotebook] {
            var value=MergeToolPreferences();value.program.enabled=true;value.program.builtIn=kind
            XCTAssertFalse(value.valid);XCTAssertThrowsError(try value.selected(path:"a.docx"))
        }
        XCTAssertFalse(WordMergeFailure.application.possiblyOpened)
        XCTAssertTrue(WordMergeFailure.automation(-1712,"timeout",possiblyOpened:true).possiblyOpened)
        XCTAssertTrue(WordMergeFailure.automation(-1743,"denied",possiblyOpened:false).localizedDescription.contains("Automation"))
    }
}
