import XCTest
@testable import TurtleGitCore

final class CommitDialogSupplementaryReadTests:XCTestCase {
    private func fixture()async throws->(URL,GitRepository) {
        // Both path outputs must retain embedded and trailing whitespace rather
        // than relying on newline-delimited multi-result rev-parse framing.
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("commit-layout-"+UUID().uuidString+"\n space ")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var accepted=false
        defer {if !accepted {try? FileManager.default.removeItem(at:root)}}
        let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let repo=GitRepository(root:root,executable:executable,libgit2Configuration:.init(enabled:false))
        _=try await repo.run(["init","-b","main"])
        _=try await repo.run(["config","user.name","Commit Layout"])
        _=try await repo.run(["config","user.email","layout@example.invalid"])
        _=try await repo.run(["config","commit.gpgsign","false"])
        accepted=true;return (root,repo)
    }
    private func seed(_ root:URL,_ repo:GitRepository)async throws {
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"))
        try await repo.stage(["file"]);_=try await repo.commit(message:"base")
    }
    private func read(_ repo:GitRepository)async throws->CommitDialogRead {
        try await repo.commitDialogRead(amend:false,amendDiffToLastCommit:true)
    }
    func testUnbornNamedAndDetachedBranchSupplementMatchesExistingReaders()async throws {
        let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let unborn=try await read(repo)
        XCTAssertEqual(unborn.branch,"main");XCTAssertFalse(unborn.hasHead)
        XCTAssertFalse(unborn.hasLFS);XCTAssertFalse(unborn.conflictIsRebase);XCTAssertNil(unborn.operation)
        try await seed(root,repo)
        _=try await repo.run(["checkout","--detach"])
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let detached=try await read(repo),oldBranch=try await repo.branch()
        XCTAssertEqual(detached.branch,oldBranch);XCTAssertEqual(detached.branch,"");XCTAssertTrue(detached.hasHead)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let retainedHead=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(retainedHead,head)
    }
    func testWorktreeSharesOnlyLFSWhileRebaseAndOperationRemainLocal()async throws {
        let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try await seed(root,repo)
        let linked=root.appendingPathComponent("linked\n worktree ")
        _=try await repo.run(["worktree","add","-b","linked-branch",linked.path])
        let child=GitRepository(root:linked,executable:repo.executable,libgit2Configuration:.init(enabled:false))
        let shared=root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at:shared.appendingPathComponent("lfs"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:shared.appendingPathComponent("rebase-merge"),withIntermediateDirectories:true)
        let original=try await read(repo),before=try await read(child)
        XCTAssertTrue(original.conflictIsRebase);XCTAssertFalse(before.conflictIsRebase)
        XCTAssertTrue(original.hasLFS);XCTAssertTrue(before.hasLFS);XCTAssertEqual(before.branch,"linked-branch")
        var gitBytes=try await child.run(["rev-parse","--absolute-git-dir"]).stdout
        if gitBytes.last==10 {gitBytes.removeLast()}
        let local=URL(fileURLWithPath:String(decoding:gitBytes,as:UTF8.self))
        try FileManager.default.createDirectory(at:local.appendingPathComponent("rebase-apply"),withIntermediateDirectories:true)
        let oid=try await child.run(["rev-parse","HEAD"]).stdout
        try oid.write(to:local.appendingPathComponent("CHERRY_PICK_HEAD"))
        let after=try await read(child),oldLFS=try await child.hasLFS(),oldRebase=try await child.conflictIsRebase(),oldOperation=try await child.commitOperation()
        XCTAssertEqual(after.hasLFS,oldLFS);XCTAssertEqual(after.conflictIsRebase,oldRebase);XCTAssertEqual(after.operation,oldOperation)
        XCTAssertTrue(after.conflictIsRebase);XCTAssertEqual(after.operation,.cherryPick)
        let unaffected=try await read(repo);XCTAssertNil(unaffected.operation)
    }
    func testOperationPrecedenceAndDirectoryTypePreserveExistingSemantics()async throws {
        let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try await seed(root,repo)
        let directory=root.appendingPathComponent(".git"),oid=try await repo.run(["rev-parse","HEAD"]).stdout
        for name in ["MERGE_HEAD","CHERRY_PICK_HEAD","REVERT_HEAD"] {try oid.write(to:directory.appendingPathComponent(name))}
        // A regular file is not an installed LFS area or an active rebase.
        for name in ["lfs","rebase-merge","rebase-apply"] {try Data().write(to:directory.appendingPathComponent(name))}
        for (name,expected) in [("MERGE_HEAD",CommitOperation.merge),("CHERRY_PICK_HEAD",.cherryPick),("REVERT_HEAD",.revert)] {
            let snapshot=try await read(repo),old=try await repo.commitOperation()
            XCTAssertEqual(snapshot.operation,expected);XCTAssertEqual(snapshot.operation,old)
            XCTAssertFalse(snapshot.hasLFS);XCTAssertFalse(snapshot.conflictIsRebase)
            try FileManager.default.removeItem(at:directory.appendingPathComponent(name))
        }
        let idle=try await read(repo);XCTAssertNil(idle.operation)
    }
    func testCapturedSupplementUsesTwoLayoutQueriesAndPrecancelLaunchesNothing()async throws {
        let (root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try await seed(root,repo)
        // Retain an unrelated tracked row so the changed read proves that its
        // index query is bounded to candidates rather than the full index.
        try Data("unchanged\n".utf8).write(to:root.appendingPathComponent("unrelated-clean"))
        try await repo.stage(["unrelated-clean"]);_=try await repo.commit(message:"clean companion")
        let wrapper=root.appendingPathComponent(".git/layout-reader"),log=root.appendingPathComponent(".git/layout-log")
        let indexArguments=root.appendingPathComponent(".git/layout-index-arguments")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        record() {
          while [ "$#" -gt 0 ]; do
            case "$1" in -C|-c) shift;shift;; --*) shift;; *) break;; esac
          done
          printf '%s\n' "${1-}" >> \(quote(log.path))
          if [ "${1-}" = ls-files ]; then
            printf '%s\\0' "$@" >> \(quote(indexArguments.path))
          fi
        }
        record "$@"
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let reader=GitRepository(root:root,executable:wrapper,libgit2Configuration:.init(enabled:false))
        func assertCommands(_ commands:[Substring],indexQueries:Int,file:StaticString=#filePath,line:UInt=#line) {
            XCTAssertEqual(commands.filter{$0=="rev-parse"}.count,4,"Two layout paths plus HEAD and its parent; no per-marker probes",file:file,line:line)
            XCTAssertEqual(commands.filter{$0=="branch"}.count,1,file:file,line:line)
            XCTAssertEqual(commands.filter{$0=="status"}.count,1,file:file,line:line)
            XCTAssertEqual(commands.filter{$0=="diff"}.count,3,file:file,line:line)
            XCTAssertEqual(commands.filter{$0=="ls-files"}.count,indexQueries,file:file,line:line)
            XCTAssertEqual(commands.count,9+indexQueries,file:file,line:line)
        }
        let indexBefore=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let clean=try await read(reader);XCTAssertEqual(clean.branch,"main")
        XCTAssertTrue(clean.entries.isEmpty);XCTAssertTrue(clean.indexFlags.isEmpty)
        XCTAssertTrue(clean.working.isEmpty);XCTAssertTrue(clean.staged.isEmpty);XCTAssertTrue(clean.unstaged.isEmpty)
        XCTAssertTrue(clean.hasHead);XCTAssertTrue(clean.hasParent)
        XCTAssertNil(clean.operation);XCTAssertNil(clean.comparisonBase)
        XCTAssertFalse(clean.hasLFS);XCTAssertFalse(clean.conflictIsRebase)
        assertCommands(try String(contentsOf:log,encoding:.utf8).split(separator:"\n"),indexQueries:0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:indexArguments.path),"A clean list must not launch index inventory")

        try Data("changed\n".utf8).write(to:root.appendingPathComponent("file"))
        try Data().write(to:log)
        let changed=try await read(reader)
        XCTAssertEqual(changed.entries.map(\.path),["file"])
        XCTAssertEqual(changed.working.map(\.path),["file"])
        XCTAssertTrue(changed.staged.isEmpty);XCTAssertEqual(changed.unstaged.map(\.path),["file"])
        XCTAssertEqual(changed.indexFlags.map(\.id),["file"])
        XCTAssertTrue(changed.indexFlags.allSatisfy{!$0.assumeUnchanged && !$0.skipWorktree})
        XCTAssertEqual(changed.branch,clean.branch);XCTAssertEqual(changed.hasHead,clean.hasHead)
        XCTAssertEqual(changed.hasParent,clean.hasParent);XCTAssertEqual(changed.comparisonBase,clean.comparisonBase)
        XCTAssertEqual(changed.operation,clean.operation);XCTAssertEqual(changed.hasLFS,clean.hasLFS)
        XCTAssertEqual(changed.conflictIsRebase,clean.conflictIsRebase)
        assertCommands(try String(contentsOf:log,encoding:.utf8).split(separator:"\n"),indexQueries:1)
        XCTAssertEqual(try Data(contentsOf:indexArguments),Data(["ls-files","--stage","-v","-z","--","file"].flatMap{Array($0.utf8)+[0]}),"The index query must retain literal candidate framing and exclude unrelated clean rows")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),indexBefore)
        try Data().write(to:indexArguments)
        try Data().write(to:log)
        let token=OperationCancellation();token.cancel()
        do {_=try await reader.commitDialogRead(amend:false,amendDiffToLastCommit:true,cancellation:token);XCTFail("Cancelled supplemental read launched")}
        catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf:log),Data())
        XCTAssertEqual(try Data(contentsOf:indexArguments),Data())
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),indexBefore)
    }
}
