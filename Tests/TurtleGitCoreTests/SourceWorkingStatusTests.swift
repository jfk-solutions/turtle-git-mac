import Foundation
import XCTest
@testable import TurtleGitCore

final class SourceWorkingStatusTests:XCTestCase {
    private let old="source 雪\t\n[?].txt",copy="copy 雪\t\n[*].txt"
    private var original:String {(0..<100).map{"unique source line \($0) abcdefghijklmnopqrstuvwxyz\n"}.joined()}
    private func fixture(commit:Bool=true) async throws -> (URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-source-status-"+UUID().uuidString).standardizedFileURL
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let git=(ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? ProcessInfo.processInfo.environment["TURTLEGIT_QA_GIT"]).map{URL(fileURLWithPath:$0)} ?? URL(fileURLWithPath:"/usr/bin/git")
        let repo=GitRepository(root:root,executable:git,askpass:nil,diffDetection:.init(percentage:50),libgit2Configuration:.init(enabled:false))
        do {
            _=try await repo.run(["init","--template=","-b","main"])
            for (key,value) in [("user.name","Source status QA"),("user.email","source-status@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.fsmonitor","false"),("core.untrackedCache","false")] {_=try await repo.run(["config",key,value])}
            try Data(original.utf8).write(to:root.appendingPathComponent(old));try await repo.stage([old])
            if commit {_=try await repo.commit(message:"base")}
            return(root,repo)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private func makeCopy(_ root:URL,_ repo:GitRepository) async throws {
        try Data((original+"source changed after copying\n").utf8).write(to:root.appendingPathComponent(old))
        try Data(original.utf8).write(to:root.appendingPathComponent(copy))
        try await repo.stage([old,copy])
    }
    func testNaturalModifiedSourceCopyPreservesXYOriginComparisonAndAutomaticIndex() async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try await makeCopy(root,repo)
        let index=root.appendingPathComponent(".git/index"),before=try Data(contentsOf:index)
        let date=try FileManager.default.attributesOfItem(atPath:index.path)[.modificationDate] as? Date
        let rows=try await repo.status(readPolicy:.automatic)
        let row=try XCTUnwrap(rows.first{$0.path==copy})
        XCTAssertEqual(row.index,"A");XCTAssertEqual(row.worktree," ");XCTAssertNil(row.originalPath)
        XCTAssertEqual(row.sourceActions,[.added]);XCTAssertNil(row.reportingOriginalPath)
        XCTAssertFalse(row.isCopied);XCTAssertFalse(row.isRenamed);XCTAssertEqual(row.actionCaption,"Added");XCTAssertEqual(row.comparisonAction,"A")
        let snapshot=try await repo.statusListFileComparison(.init(entry:row,base:.revision("HEAD"),isSubmodule:false))
        XCTAssertEqual(snapshot.files.first?.action,"A");XCTAssertNil(snapshot.files.first?.oldPath)
        let content=try await repo.comparisonFile(snapshot,path:copy)
        XCTAssertTrue(content.base.bytes.isEmpty);XCTAssertEqual(snapshot.from,.emptyTree);XCTAssertEqual(content.destination.bytes,Data(original.utf8))
        let captured=try await repo.commitDialogRead(amend:false,amendDiffToLastCommit:true)
        XCTAssertEqual(captured.entries.first{$0.path==copy},row)
        let add=try await repo.addDialogSelection(paths:[copy,old],includeIgnored:false)
        XCTAssertEqual(add.entries.first{$0.path==copy}?.status,row)
        let history=try await repo.workingTreeHistory()
        XCTAssertEqual(history?.files.first{$0.path==copy}?.action,"A");XCTAssertNil(history?.files.first{$0.path==copy}?.oldPath)
        XCTAssertEqual(try Data(contentsOf:index),before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:index.path)[.modificationDate] as? Date,date)
    }
    func testCopiedBytesCheckboxCommitNeverCommitsOrRemovesModifiedSource() async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try await makeCopy(root,repo)
        let rows=try await repo.status(readPolicy:.automatic)
        XCTAssertEqual(try XCTUnwrap(rows.first{$0.path==copy}).reportingActions,[.added])
        var options=CommitOptions();options.checkboxIndexPolicy = .init(paths:[copy,old],readdUnchecked:false)
        _=try await repo.commitSelected(message:"copy alone",paths:[copy],options:options)
        let source=try await repo.run(["show","HEAD:"+old]).stdout,destination=try await repo.run(["show","HEAD:"+copy]).stdout
        XCTAssertEqual(source,Data(original.utf8));XCTAssertEqual(destination,Data(original.utf8))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(old)),Data((original+"source changed after copying\n").utf8))
    }
    func testCachedAddedThenWholeRenameKeepsFirstAbsentOriginAndActualIndex() async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data(original.utf8).write(to:root.appendingPathComponent(copy));try await repo.stage([copy])
        try FileManager.default.removeItem(at:root.appendingPathComponent(old))
        let rows=try await repo.status(readPolicy:.automatic),row=try XCTUnwrap(rows.first{$0.path==copy})
        XCTAssertEqual(row.index,"A");XCTAssertNil(row.originalPath)
        XCTAssertTrue(row.reportingActions.contains(.added));XCTAssertTrue(row.reportingActions.contains(.renamed))
        XCTAssertNil(row.reportingOriginalPath,"Cached A is first, so later whole R cannot overwrite its absent origin")
        XCTAssertEqual(row.actionCaption,"Added");XCTAssertEqual(row.comparisonAction,"A")
        var options=CommitOptions();options.checkboxIndexPolicy = .init(paths:[copy,old],readdUnchecked:false)
        _=try await repo.commitSelected(message:"added destination only",paths:[copy],options:options)
        let source=try await repo.run(["show","HEAD:"+old]).stdout
        XCTAssertEqual(source,Data(original.utf8));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(old).path))
    }
    func testUnchangedSourceIsNotFindCopiesHarderAndUnbornRemainsAdded() async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data(original.utf8).write(to:root.appendingPathComponent(copy));try await repo.stage([copy])
        let rows=try await repo.status(readPolicy:.automatic),row=try XCTUnwrap(rows.first{$0.path==copy})
        XCTAssertFalse(row.isCopied);XCTAssertEqual(row.reportingActions,[.added]);XCTAssertNil(row.reportingOriginalPath)
        let token=OperationCancellation();token.cancel()
        do {_=try await repo.status(readPolicy:.automatic,cancellation:token);XCTFail("Cancelled enrichment admitted")}catch is OperationCancellationFailure {}
        let(unborn,initial)=try await fixture(commit:false);defer{try? FileManager.default.removeItem(at:unborn)}
        let first=try await initial.status(readPolicy:.automatic)
        XCTAssertEqual(first.first?.index,"A");XCTAssertNil(first.first?.sourceActions)
        let null=try await initial.sourceWorkingStatus(first,base:.emptyTree)
        XCTAssertEqual(null,first)
        do {_=try await initial.sourceWorkingStatus(first,base:.workingTree);XCTFail("Working base admitted")}catch SourceWorkingStatusFailure.invalidBase {}
    }
    private func raw(_ code:String,_ paths:[String])->Data {
        Data((":100644 100644 "+String(repeating:"1",count:40)+" "+String(repeating:"2",count:40)+" "+code+"\0"+paths.joined(separator:"\0")+"\0").utf8)
    }
    func testRawNumstatTripletsUnionPrecedenceLiteralNamesAndIdentity() throws {
        let composed="é",decomposed="e\u{301}",dest="-dest\t\n[*]"
        let stream=raw("C100",[composed,dest])+raw("M",[dest])+Data(("0\t0\t\0"+composed+"\0"+dest+"\0").utf8)
        let parsed=try SourceWorkingStatus.parse(stream)
        let row=StatusEntry(path:dest,index:"A",worktree:" ")
        let accepted=try XCTUnwrap(SourceWorkingStatus.applying(parsed,to:[row]).first)
        XCTAssertEqual(accepted.reportingActions,[.copied,.modified]);XCTAssertEqual(accepted.actionCaption,"Modified")
        XCTAssertEqual(Array(try XCTUnwrap(accepted.reportingOriginalPath).utf8),Array(composed.utf8))
        var other=accepted;other.sourceOriginalPath=decomposed
        XCTAssertNotEqual(accepted,other);XCTAssertEqual(Set([accepted,other]).count,2)
        let absent=SourceWorkingStatus.applying(try SourceWorkingStatus.parse(raw("A",[dest])+raw("R100",[composed,dest])),to:[row])[0]
        XCTAssertNil(absent.reportingOriginalPath);XCTAssertTrue(absent.isRenamed)
        let canonical=SourceWorkingStatus.applying(try SourceWorkingStatus.parse(raw("M",[composed])),to:[StatusEntry(path:decomposed,index:" ",worktree:"M")])[0]
        XCTAssertNil(canonical.sourceActions)
        XCTAssertNotEqual(row,StatusEntry(path:dest,index:"A",worktree:" ",sourceActions:[]))
    }
    func testControlledCopyAndRenameOldNameAliasMatchesPinnedDefault() throws {
        let renamed=StatusEntry(path:"new",originalPath:"old",index:"R",worktree:" ")
        for action in ["A","D"] {
            let records=try SourceWorkingStatus.parse(raw("R100",["old","new"])+raw(action,["old"]))
            let row=SourceWorkingStatus.applying(records,to:[renamed])[0]
            XCTAssertEqual(row.reportingActions,[.renamed]);XCTAssertEqual(row.reportingOriginalPath,"old")
        }
        // Accepted C protocol coverage is controlled, distinct from natural
        // source-CLI discovery: C-M command order naturally reports A.
        let copied=StatusEntry(path:"new",index:"A",worktree:" ")
        let records=try SourceWorkingStatus.parse(raw("C100",["old","new"])+raw("M",["old"]))
        let row=SourceWorkingStatus.applying(records,to:[copied])[0]
        XCTAssertEqual(row.reportingActions,[.copied,.modified]);XCTAssertTrue(row.isCopied)
        XCTAssertEqual(row.reportingOriginalPath,"old");XCTAssertEqual(row.actionCaption,"Modified")
    }
    func testConflictMissingAndRetainedDeletionPolicies() throws {
        let conflict=StatusEntry(path:"conflict",index:"A",worktree:"U")
        XCTAssertEqual(conflict.reportingActions,[.unmerged]);XCTAssertEqual(conflict.comparisonAction,"M")
        let merged=SourceWorkingStatus.applying([.init(path:"conflict",origin:nil,actions:.unmerged)],to:[conflict])[0]
        XCTAssertEqual(merged.actionCaption,"Conflicted");XCTAssertEqual(merged.index,"A")
        let missing=StatusEntry(path:"gone",index:" ",worktree:"D",sourceActions:[.copied,.missing],sourceOriginalPath:"old")
        XCTAssertFalse(missing.canCompareWithBaseFromStatusList);XCTAssertEqual(missing.actionCaption,"Missing")
        let deleted=StatusEntry(path:"gone",index:"D",worktree:" ",hasUnversionedCopy:true,sourceActions:.deleted)
        XCTAssertFalse(deleted.canCompareWithBaseFromStatusList);XCTAssertEqual(deleted.actionCaption,"Deleted")
    }
    func testMalformedAndInvalidUTF8NeverPublishesAliasedOrigin() throws {
        XCTAssertThrowsError(try SourceWorkingStatus.parse(raw("R101",["old","new"])))
        XCTAssertThrowsError(try SourceWorkingStatus.parse(Data(":100644 100644 1 2 R100\0old\0".utf8)))
        XCTAssertThrowsError(try SourceWorkingStatus.parse(Data("0\t0\t\0old\0".utf8)))
        // Explicit byte source avoids String replacement aliases.
        let header=Data((":100644 100644 "+String(repeating:"1",count:40)+" "+String(repeating:"2",count:40)+" C100\0").utf8)
        let parsed=try SourceWorkingStatus.parse(header+Data([255,0])+Data("new\0".utf8))
        XCTAssertTrue(parsed.isEmpty)
    }
}

extension SourceWorkingStatusTests {
    func testRealCachedRenameSuppressesLaterDeletionAndKeepsPorcelainFacts() async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=try await repo.run(["mv","--",old,copy])
        let renamedRows=try await repo.status(readPolicy:.automatic),renamed=try XCTUnwrap(renamedRows.first{$0.path==copy})
        XCTAssertEqual(renamed.index,"R");XCTAssertTrue(renamed.isRenamed);XCTAssertEqual(renamed.reportingOriginalPath,old)
        try FileManager.default.removeItem(at:root.appendingPathComponent(copy))
        let goneRows=try await repo.status(readPolicy:.automatic),gone=try XCTUnwrap(goneRows.first{$0.path==copy})
        XCTAssertEqual(gone.index,"R");XCTAssertEqual(gone.worktree,"D")
        let whole=try await repo.run(["diff-index","--raw","HEAD","--numstat","-C50%","-M50%","-z","--"]).stdout
        XCTAssertTrue(try SourceWorkingStatus.parse(whole).contains{$0.path==old && $0.actions == .deleted})
        XCTAssertEqual(gone.reportingActions,[.renamed,.missing],"Later D at the old-name alias must not add Deleted to the cached exact-R row")
        XCTAssertEqual(gone.reportingOriginalPath,old);XCTAssertFalse(gone.canCompareWithBaseFromStatusList)
        _=try await repo.run(["reset","--hard","HEAD"])
        _=try await repo.run(["rm","--cached","--",old])
        try Data("*.ignored\n".utf8).write(to:root.appendingPathComponent(".gitignore"))
        try Data("private ignored\n".utf8).write(to:root.appendingPathComponent("note.ignored"))
        let retainedRows=try await repo.status(readPolicy:.automatic),retained=try XCTUnwrap(retainedRows.first{$0.path==old})
        XCTAssertEqual(retained.index,"D");XCTAssertTrue(retained.hasUnversionedCopy);XCTAssertTrue(retained.reportingActions.contains(.deleted))
        XCTAssertEqual(retainedRows.first{$0.path=="note.ignored"}?.state,.ignored)
        let filtered=try await repo.status(readPolicy:.automatic,includeIgnored:false)
        XCTAssertFalse(filtered.contains{$0.path=="note.ignored"})
    }
    func testExplicitPinnedParentProjectionAndMalformedRawFailClosed() async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let parent=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        try await makeCopy(root,repo);_=try await repo.commit(message:"copied commit")
        // No HEAD-relative changes; amend's final parent projection supplies its
        // actual rows and pinned base, independently of current status fastpath.
        let projected=[StatusEntry(path:copy,index:"A",worktree:" "),StatusEntry(path:old,index:"M",worktree:" ")]
        let accepted=try await repo.sourceWorkingStatus(projected,base:.revision(parent))
        XCTAssertEqual(try XCTUnwrap(accepted.first{$0.path==copy}).reportingActions,[.added])
        XCTAssertNil(accepted.first{$0.path==copy}?.reportingOriginalPath)
        let amend=try await repo.commitDialogRead(amend:true,amendDiffToLastCommit:false)
        let copied=try XCTUnwrap(amend.entries.first{$0.path==copy})
        XCTAssertEqual(copied.reportingActions,[.added]);XCTAssertNil(copied.reportingOriginalPath)
        for malformed in [Data(":100644 100644 bad bad R100\0only-old\0".utf8),raw("Z",["bad"]),Data("-\tx\tpath\0".utf8)] {
            XCTAssertThrowsError(try SourceWorkingStatus.parse(malformed))
        }
        do {_=try await repo.sourceWorkingStatus(projected,base:.revision("HEAD"));XCTFail("Unpinned projection admitted")}catch SourceWorkingStatusFailure.invalidBase {}
    }
}

extension SourceWorkingStatusTests {
    func testConfiguredHundredPorcelainAddedKeepsSourceDefaultFiftyRenameShape() async throws {
        let(root,initial)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=try await initial.run(["mv","--",old,copy])
        try Data((original+"small rename edit\n").utf8).write(to:root.appendingPathComponent(copy));try await initial.stage([copy])
        let repo=GitRepository(root:root,executable:initial.executable,askpass:nil,diffDetection:.init(percentage:100),libgit2Configuration:.init(enabled:false))
        let porcelain=try await repo.status(readPolicy:.automatic,sourceReporting:false)
        XCTAssertTrue(porcelain.contains{$0.path==old && $0.index=="D"})
        XCTAssertTrue(porcelain.contains{$0.path==copy && $0.index=="A"})
        let report=try await repo.status(readPolicy:.automatic),row=try XCTUnwrap(report.first{$0.path==copy})
        XCTAssertFalse(report.contains{$0.path==old},"Cached source50 R must consume later whole100 old-path D")
        XCTAssertEqual(row.index,"A");XCTAssertEqual(row.worktree," ");XCTAssertNil(row.originalPath)
        XCTAssertEqual(row.reportingActions,[.renamed]);XCTAssertEqual(row.reportingOriginalPath,old)
        XCTAssertEqual(row.actionCaption,"Renamed");XCTAssertEqual(row.comparisonAction,"R")
    }
    func testFoldedDeletionLocalStateSurvivesOldNameAliasWithoutInventingIgnoredRows() throws {
        for local in ["??","!!"] {
            for reversed in [false,true] {
                let packets=["D  old\0",local+" old\0"]
                let rows=StatusEntry.parse(Data((reversed ? packets.reversed().joined():packets.joined()).utf8))
                let oldRow=try XCTUnwrap(rows.first)
                XCTAssertTrue(oldRow.hasUnversionedCopy);XCTAssertEqual(oldRow.unversionedCopyState,local=="!!" ? .ignored:.untracked)
                let dest=StatusEntry(path:"new",index:"A",worktree:" ")
                let report=SourceWorkingStatus.applying(try SourceWorkingStatus.parse(raw("R100",["old","new"])+raw("D",["old"])),to:rows+[dest])
                let retained=try XCTUnwrap(report.first{$0.path=="old"})
                XCTAssertEqual(String([retained.index,retained.worktree]),local)
                XCTAssertNil(retained.sourceActions);XCTAssertFalse(retained.hasUnversionedCopy)
                XCTAssertEqual(report.first{$0.path=="new"}?.reportingActions,[.renamed])
            }
        }
        let unknown=StatusEntry(path:"old",index:"D",worktree:" ",hasUnversionedCopy:true)
        let report=SourceWorkingStatus.applying(try SourceWorkingStatus.parse(raw("R100",["old","new"])),to:[unknown])
        XCTAssertEqual(report,[unknown],"Unknown legacy local-state metadata must preserve its row, not invent ignored/untracked visibility")
    }
}
