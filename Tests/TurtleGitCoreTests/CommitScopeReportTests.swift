import XCTest
@testable import TurtleGitCore

final class CommitScopeReportTests:XCTestCase {
    func testRepositoryScopeKeysAreIndependentAndKeepExactSpelling() {
        let a=FileTransferPaths.fileURL("/private/café/repo"),b=FileTransferPaths.fileURL("/private/cafe\u{301}/repo")
        XCTAssertFalse(CommitScopePreference.key(root:a).utf8.elementsEqual(CommitScopePreference.key(root:b).utf8))
        XCTAssertEqual(CommitScopePreference.key(root:FileTransferPaths.fileURL("/private/repo/./child/..")),"Commit.ShowWholeProject./private/repo")
        let suite="TurtleGit.ScopeReport.Core."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        XCTAssertFalse(defaults.bool(forKey:CommitScopePreference.key(root:a)))
        defaults.set(true,forKey:CommitScopePreference.key(root:a))
        XCTAssertTrue(defaults.bool(forKey:CommitScopePreference.key(root:a)))
        XCTAssertFalse(defaults.bool(forKey:CommitScopePreference.key(root:FileTransferPaths.fileURL("/private/other"))))
    }
    func testReportUsesCheckedMembershipSuppliedDisplayOrderAndExactNames() {
        let a="café.txt",b="cafe\u{301}.txt",c="line\n*.txt"
        let entries=StatusEntry.parse(Data((" M "+a+"\0?? "+b+"\0 M "+c+"\0").utf8))
        let output=CommitFileListReport.text(entries:[entries[2],entries[1],entries[0]],checked:GitPathSet([a,c]))
        let expected="Modified   "+c+"\nModified   "+a+"\n"
        XCTAssertTrue(output.utf8.elementsEqual(expected.utf8))
        XCTAssertFalse(output.utf8.contains(0))
        let bOnly=CommitFileListReport.text(entries:entries,checked:GitPathSet([b]))
        XCTAssertTrue(bOnly.utf8.elementsEqual(("Added      "+b+"\n").utf8))
    }
    func testSourceActionPriorityAndRenameCopyDisplayPaths() {
        for (code,label) in [("UU","Conflict"),("AM","Added"),(" D","Missing"),("D ","Deleted"),("RM","Modified"),("R ","Rename"),("C ","Copy"),(" T","Modified"),("??","Added"),("!!","Ignored")] {
            let entry=StatusEntry.parse(Data((code+" path\0"+(code.first=="R" || code.first=="C" ? "old\0":"")).utf8))[0]
            XCTAssertEqual(CommitFileListReport.actionLabel(entry),label,code)
        }
        let renamed=StatusEntry.parse(Data("R  dir/new\0dir/old\0".utf8))[0]
        XCTAssertEqual(CommitFileListReport.text(entries:[renamed],checked:[renamed.path]),"Rename     dir/new (from dir/old)\n")
        XCTAssertEqual(CommitFileListReport.text(entries:[renamed],checked:[renamed.path],abbreviateRenames:true),"Rename     dir/{old => new}\n")
        let added=StatusEntry.parse(Data("A  copy\0".utf8))[0]
        let stats=CommitFile(path:"copy",oldPath:"source",action:"C100",added:0,removed:0,hasStatistics:true,isSubmodule:false)
        XCTAssertEqual(CommitFileListReport.actionLabel(added,statistics:stats),"Copy")
        XCTAssertEqual(CommitFileListReport.text(entries:[added],checked:[added.path],statistics:["copy":stats]),"Copy       copy (from source)\n")
    }
    func testReportLocalizesOnlyKnownActionAndPadsUTF16WithoutTruncation() {
        let entries=StatusEntry.parse(Data(" M arbitrary /path\0?? raw.txt\0".utf8))
        let output=CommitFileListReport.text(entries:entries,checked:GitPathSet(entries.map(\.path)),label:{$0=="Modified" ? "Changed🔧":$0})
        XCTAssertEqual(output,"Changed🔧  arbitrary /path\nAdded      raw.txt\n")
        let long=CommitFileListReport.text(entries:[entries[0]],checked:[entries[0].path],label:{_ in "Long action caption"})
        XCTAssertEqual(long,"Long action caption arbitrary /path\n")
    }
    func testDeclaredProjectLanguagePolicyDefaultsAndLayerPrecedence()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitScopeReport-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let repository=GitRepository(root:root,executable:URL(fileURLWithPath:"/usr/bin/git"))
        _ = try await repository.run(["init","-b","main"])
        let initial=try await repository.commitFileListReportInEnglish();XCTAssertTrue(initial)
        let project=root.appendingPathComponent(".tgitconfig")
        try Data("[tsvn]\nlogfilelistenglish = false\n".utf8).write(to:project)
        let configured=try await repository.commitFileListReportInEnglish();XCTAssertFalse(configured)
        _ = try await repository.run(["config","--local","tsvn.logfilelistenglish","yes"])
        let overridden=try await repository.commitFileListReportInEnglish();XCTAssertTrue(overridden)
        _ = try await repository.run(["config","--local","tsvn.logfilelistenglish","0"])
        let numeric=try await repository.commitFileListReportInEnglish();XCTAssertFalse(numeric)
        _ = try await repository.run(["config","--local","tsvn.logfilelistenglish","not-a-boolean"])
        do {_ = try await repository.commitFileListReportInEnglish();XCTFail("Malformed report policy silently accepted")} catch GitConfigurationFailure.invalidValue {}
    }
}
