import XCTest
@testable import TurtleGitCore

final class CommitDialogReadTests:XCTestCase {
    private let oid=String(repeating:"1",count:40),zero=String(repeating:"0",count:40)
    private func fixture()async throws->(URL,GitRepository) {
        let (root,initial)=try await CommitSelectionTests().fixture()
        let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? initial.executable.path)
        return (root,GitRepository(root:root,executable:executable,libgit2Configuration:.init(enabled:false)))
    }
    func testCombinedRawNumstatRetainsBinaryRenameGitlinkAndControlCharacters()throws {
        let old="old\tname\n",new=":new\tname\n",module="gitlink",binary="binary",stale="stat-only"
        let raw=":100644 100644 \(oid) \(oid) R100\0\(old)\0\(new)\0:160000 160000 \(oid) \(oid) M\0\(module)\0:100644 100644 \(oid) \(zero) M\0\(binary)\0:100644 100644 \(oid) \(zero) M\0\(stale)\0"
        let stats="0\t0\t\0\(old)\0\(new)\0"+"1\t1\t\(module)\0-\t-\t\(binary)\0"
        let files=try CommitCombinedDiff.parse(Data((raw+stats).utf8))
        XCTAssertEqual(files.map(\.path),[new,module,binary]);XCTAssertEqual(files[0].oldPath,old)
        XCTAssertEqual(files[0].action,"R100");XCTAssertEqual(files[0].added,0)
        XCTAssertTrue(files[1].isSubmodule);XCTAssertTrue(files[2].hasStatistics)
        XCTAssertNil(files[2].added);XCTAssertNil(files[2].removed)
    }
    func testCombinedProtocolRefusesTruncationOrphanAndMismatchedRenameButAllowsUnmergedMultiplicity()throws {
        let first=":000000 100644 \(zero) \(oid) U\0conflict\0",second=":100644 100644 \(oid) \(zero) M\0conflict\0"
        let files=try CommitCombinedDiff.parse(Data((first+second+"0\t0\tconflict\0"+"2\t1\tconflict\0").utf8))
        XCTAssertEqual(files.map(\.action),["U","M"]);XCTAssertEqual(files.map(\.added),[2,2])
        for invalid in ["1\t0\torphan\0",first+"0\t0\tother\0",first+"0\t0\tconflict",":100644 100644 \(oid) \(oid) R100\0old\0new\0"+"0\t0\t\0wrong\0new\0",first+"0\t0\tconflict\0"+"0\t0\tconflict\0",first+"-\t0\tconflict\0",first+"0\t-\tconflict\0",first+"999999999999999999999999999\t0\tconflict\0"] {
            XCTAssertThrowsError(try CommitCombinedDiff.parse(Data(invalid.utf8)),invalid.debugDescription)
        }
    }
    private func counted(_ repo:GitRepository)throws->(GitRepository,URL) {
        let wrapper=repo.root.appendingPathComponent(".git/commit-read-wrapper"),log=repo.root.appendingPathComponent(".git/commit-read-log")
        func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        command() {
          while [ "$#" -gt 0 ]; do
            case "$1" in -C|-c) shift;shift;; --*) shift;; *) break;; esac
          done
          printf '%s\n' "${1-}" >> \(quote(log.path))
        }
        command "$@"
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        return (GitRepository(root:repo.root,executable:wrapper,libgit2Configuration:.init(enabled:false)),log)
    }
    private func assertCommands(_ log:URL,file:StaticString = #filePath,line:UInt = #line)throws {
        let commands=try String(contentsOf:log,encoding:.utf8).split(separator:"\n")
        XCTAssertEqual(commands.filter{$0=="diff"}.count,3,file:file,line:line)
        XCTAssertEqual(commands.filter{$0=="status"}.count,1,file:file,line:line)
        XCTAssertEqual(commands.filter{$0=="ls-files"}.count,1,file:file,line:line)
    }
    func testCapturedReadMatchesExactMixedClassicAndStagingFactsWithoutNineDiffPasses()async throws {
        let helper=CommitSelectionTests(),(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let old="old\tfile\n",new="new\tfile\n",partial="partial",deleted="deleted"
        for (path,text) in [(old,String(repeating:"rename contents\n",count:20)),(partial,"base\n"),(deleted,"old\n")] {try helper.write(root,path,text)}
        try Data([0,1,2,3]).write(to:root.appendingPathComponent("binary"))
        try await repo.stage([old,partial,deleted,"binary"]);_=try await repo.commit(message:"base")
        try Data([0,7,8,9]).write(to:root.appendingPathComponent("binary"))
        _=try await repo.run(["mv","--",old,new]);try helper.write(root,partial,"staged\n");try await repo.stage([partial]);try helper.write(root,partial,"working\n")
        _=try await repo.run(["rm","--",deleted]);try helper.write(root,deleted,"recreated local copy\n")
        try helper.write(root,":untracked\tfile\n","new\n")
        let beforeHead=try await repo.run(["rev-parse","HEAD"]).stdout,beforeIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let (reader,log)=try counted(repo),snapshot=try await reader.commitDialogRead(amend:false,amendDiffToLastCommit:true)
        try assertCommands(log)
        XCTAssertTrue(snapshot.hasHead);XCTAssertFalse(snapshot.hasParent);XCTAssertNil(snapshot.comparisonBase)
        XCTAssertTrue(snapshot.entries.contains{$0.path==deleted && $0.hasUnversionedCopy})
        XCTAssertTrue(snapshot.entries.contains{$0.path==partial && $0.index=="M" && $0.worktree=="M"})
        XCTAssertTrue(snapshot.entries.contains{$0.path==new && $0.originalPath==old})
        let binary=try XCTUnwrap(snapshot.working.first{$0.path=="binary"});XCTAssertTrue(binary.hasStatistics);XCTAssertNil(binary.added);XCTAssertNil(binary.removed)
        let expectedStatus=try await repo.commitDialogStatus(amendToParent:false,refreshIndex:false)
        XCTAssertEqual(snapshot.entries,expectedStatus)
        let working=try await repo.workingTreeFiles(),staged=try await repo.stagingFiles(staged:true),unstaged=try await repo.stagingFiles(staged:false)
        XCTAssertEqual(snapshot.working,working);XCTAssertEqual(snapshot.staged,staged);XCTAssertEqual(snapshot.unstaged,unstaged)
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(afterHead,beforeHead)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),beforeIndex)
    }
    func testParentAmendReusesThreeInventoriesAndKeepsIndexOnlyCancelledWorktreeRow()async throws {
        let helper=CommitSelectionTests(),(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try helper.write(root,"file","parent\n");try await repo.stage(["file"]);_=try await repo.commit(message:"parent")
        let parent=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try helper.write(root,"file","last commit\n");try await repo.stage(["file"]);_=try await repo.commit(message:"last")
        try helper.write(root,"file","staged\n");try await repo.stage(["file"]);try helper.write(root,"file","parent\n")
        let (reader,log)=try counted(repo),snapshot=try await reader.commitDialogRead(amend:true,amendDiffToLastCommit:false)
        try assertCommands(log);XCTAssertEqual(snapshot.comparisonBase,parent)
        XCTAssertTrue(snapshot.hasParent);XCTAssertTrue(snapshot.entries.contains{$0.path=="file" && $0.index=="M"})
        let old=try await repo.commitDialogStatus(amendToParent:true,refreshIndex:false),working=try await repo.workingTreeFiles(amendToParent:true),staged=try await repo.stagingFiles(staged:true,base:parent)
        XCTAssertEqual(snapshot.entries,old);XCTAssertEqual(snapshot.working,working);XCTAssertEqual(snapshot.staged,staged)
    }
    func testUnbornReadAndPrecancelKeepIndexAndAvoidLaunchingOwnedChildren()async throws {
        let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("new\n".utf8).write(to:root.appendingPathComponent("new"));try await repo.stage(["new"])
        let before=try Data(contentsOf:root.appendingPathComponent(".git/index")),(reader,log)=try counted(repo)
        let snapshot=try await reader.commitDialogRead(amend:false,amendDiffToLastCommit:true)
        try assertCommands(log);XCTAssertFalse(snapshot.hasHead);XCTAssertFalse(snapshot.hasParent)
        XCTAssertEqual(snapshot.entries.map(\.path),["new"]);XCTAssertEqual(snapshot.staged.map(\.action),["A"])
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),before)
        try Data().write(to:log);let token=OperationCancellation();token.cancel()
        do {_=try await reader.commitDialogRead(amend:false,amendDiffToLastCommit:true,cancellation:token);XCTFail("Precancelled display read launched")}catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf:log),Data())
    }
    func testOneDisplayIndexRetainsConflictStagesGitlinksAndLowercaseFlags()async throws {
        let helper=CommitSelectionTests(),(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try helper.write(root,"conflict","base\n");try await repo.stage(["conflict"]);_=try await repo.commit(message:"base")
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try helper.write(root,"flagged","new\n");try await repo.stage(["flagged"])
        _=try await repo.run(["update-index","--assume-unchanged","--","flagged"])
        _=try await repo.run(["update-index","--skip-worktree","--","flagged"])
        _=try await repo.run(["update-index","--add","--cacheinfo","160000",head,"module"])
        var blobs=[String]()
        for text in ["base\n","ours\n","theirs\n"] {blobs.append(try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).text.trimmingCharacters(in:.newlines))}
        var input="0 \(zero)\tconflict\0"
        for (offset,blob) in blobs.enumerated() {input += "100644 \(blob) \(offset+1)\tconflict\0"}
        _=try await repo.run(["update-index","-z","--index-info"],input:Data(input.utf8))
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),(reader,log)=try counted(repo)
        let snapshot=try await reader.commitDialogRead(amend:false,amendDiffToLastCommit:true)
        try assertCommands(log)
        XCTAssertTrue(snapshot.submodules.contains("module"))
        XCTAssertTrue(snapshot.entries.contains{$0.path=="conflict" && $0.state == .conflicted})
        let flagged=try XCTUnwrap(snapshot.indexFlags.first{$0.id=="flagged"})
        XCTAssertTrue(flagged.assumeUnchanged);XCTAssertTrue(flagged.skipWorktree)
        let old=try await repo.workingTreeFiles(),unstaged=try await repo.stagingFiles(staged:false)
        XCTAssertEqual(snapshot.working,old);XCTAssertEqual(snapshot.unstaged,unstaged)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }

}
