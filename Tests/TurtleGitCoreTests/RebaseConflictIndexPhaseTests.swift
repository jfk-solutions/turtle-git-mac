import XCTest
@testable import TurtleGitCore

final class RebaseConflictIndexPhaseTests: XCTestCase {
    struct Fixture { let root:URL;let repository:GitRepository;let path:String }
    func fixture() async throws -> Fixture {
        let (root,repository,path)=try await RebaseTests().fixture(conflict:true)
        do {
            _=try await repository.run(["config","commit.gpgSign","false"])
            _=try await repository.run(["config","core.hooksPath","/dev/null"])
            var plan=try await repository.rebasePlan(RebaseTests().options())
            plan.entries[0].action = .edit;plan.entries[1].action = .skip
            _=try await repository.startRebase(plan,editorExecutable:RebaseTests().editor)
            let state=try await repository.rebaseState();XCTAssertFalse(state.conflicts.isEmpty)
            try Data("resolved selection\n".utf8).write(to:root.appendingPathComponent(path))
            try await repository.stage([path])
            return .init(root:root,repository:repository,path:path)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    func hook(_ f:Fixture,body:String) async throws {
        let directory=f.root.appendingPathComponent(".git/phase-hooks",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file=directory.appendingPathComponent("pre-commit")
        try Data(("#!/bin/sh\nset -e\n"+body+"\n").utf8).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        _=try await f.repository.run(["config","core.hooksPath",directory.path])
    }
    func hasIndex(_ repository:GitRepository,_ path:String) async throws -> Bool {
        let data=try await repository.run(["ls-files","-z","--",path]).stdout
        return data == Data((path+"\0").utf8)
    }
    func testFirstHookTreeSurvivesMessageAmendWithoutUncheckedAddition() async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let repo=f.repository,excluded="unchecked addition 雪.txt"
        try Data("excluded content\n".utf8).write(to:f.root.appendingPathComponent(excluded));try await repo.stage([excluded])
        let quotedPath="'"+f.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        let git="'"+repo.executable.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        try await hook(f,body:"""
        if [ ! -f .git/phase-hook-ran ]; then
          printf 'hook selected content\\n' > \(quotedPath)
          \(git) add -- \(quotedPath)
          : > .git/phase-hook-ran
        fi
        """)
        let before=try await repo.rebaseSessionSnapshot()
        let first=try await repo.beginRebaseConflictMessage(rawMessage:"Reviewed hook result",paths:[f.path],expected:before.state,expectedHead:before.head,indexPolicy:.init(paths:[f.path,excluded],readdUnchecked:false))
        XCTAssertEqual(first.exitCode,0)
        let firstHead=try await repo.rebaseCommit("HEAD")
        let firstBlob=try await repo.run(["show","HEAD:"+f.path]).stdout
        let firstIndex=try await repo.run(["show",":"+f.path]).stdout
        let excludedBefore=try await hasIndex(repo,excluded)
        XCTAssertEqual(firstBlob,Data("hook selected content\n".utf8));XCTAssertEqual(firstIndex,firstBlob);XCTAssertFalse(excludedBefore)
        let pending=try await repo.rebaseSessionSnapshot()
        _=try await repo.completeRebaseConflictMessage(amendMessage:"Reviewed hook result",expected:pending.state,expectedHead:pending.head,editorExecutable:RebaseTests().editor,rawMessage:"Reviewed hook result")
        let finalHead=try await repo.rebaseCommit("HEAD"),finalTree=try await repo.run(["rev-parse","HEAD^{tree}"]).stdout
        let firstTree=try await repo.run(["rev-parse",firstHead.hash+"^{tree}"]).stdout
        let finalIndex=try await repo.run(["show",":"+f.path]).stdout,excludedAfter=try await hasIndex(repo,excluded)
        XCTAssertEqual(finalHead.subject,"Reviewed hook result");XCTAssertEqual(finalTree,firstTree);XCTAssertEqual(finalIndex,firstBlob);XCTAssertFalse(excludedAfter)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(excluded)),Data("excluded content\n".utf8))
        _=try await repo.abortRebase()
    }
    func testUncheckedAdditionRestoresOnlyAfterSuccessOrIgnoreNotFailureOrRetry() async throws {
        for readd in [false,true] {for ignore in [false,true] {
            let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
            let repo=f.repository,path="unchecked-new.txt",bytes=Data("preserved unchecked bytes\n".utf8)
            try bytes.write(to:f.root.appendingPathComponent(path));try await repo.stage([path])
            try await hook(f,body:"""
            if [ -f .git/first-phase-hook ]; then
              printf 'owned secondary failure\\n' >&2
              exit 73
            fi
            : > .git/first-phase-hook
            """)
            let before=try await repo.rebaseSessionSnapshot()
            _=try await repo.beginRebaseConflictMessage(rawMessage:"Edited second phase",paths:[f.path],expected:before.state,expectedHead:before.head,indexPolicy:.init(paths:[f.path,path],readdUnchecked:readd))
            let afterFirst=try await hasIndex(repo,path);XCTAssertFalse(afterFirst,"Restored before secondary amendment")
            let pending=try await repo.rebaseSessionSnapshot()
            var caught:RebaseCleanCommitFailure?
            do {_=try await repo.completeRebaseConflictMessage(amendMessage:"Edited second phase",expected:pending.state,expectedHead:pending.head,editorExecutable:RebaseTests().editor,rawMessage:"Edited second phase");XCTFail("Expected secondary hook failure")}
            catch let failure as RebaseCleanCommitFailure {caught=failure}
            let failure=try XCTUnwrap(caught),failed=try await repo.rebaseSessionSnapshot()
            let afterFailure=try await hasIndex(repo,path);XCTAssertFalse(afterFailure,"Restored after failed amendment")
            XCTAssertEqual(failed.head,pending.head)
            if ignore {
                _=try await repo.ignoreRebaseCleanCommitFailure(failure,expected:failed.state,expectedHead:failed.head,editorExecutable:RebaseTests().editor)
            } else {
                _=try await repo.retryRebaseCleanCommitFailure(failure,expected:failed.state,expectedHead:failed.head)
                let afterRetry=try await hasIndex(repo,path);XCTAssertFalse(afterRetry,"Retry must only return to editor")
                _=try await repo.run(["config","core.hooksPath","/dev/null"])
                let retry=try await repo.rebaseSessionSnapshot()
                _=try await repo.completeRebaseConflictMessage(amendMessage:"Approved repaired message",expected:retry.state,expectedHead:retry.head,editorExecutable:RebaseTests().editor,rawMessage:"Approved repaired message")
            }
            let restored=try await hasIndex(repo,path),head=try await repo.rebaseCommit("HEAD")
            let committed=try await repo.run(["ls-tree","-z","HEAD","--",path]).stdout
            XCTAssertEqual(restored,readd);XCTAssertTrue(committed.isEmpty,"Unchecked addition entered committed tree")
            XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(path)),bytes)
            XCTAssertEqual(head.hash == pending.head,ignore)
            if readd {let staged=try await repo.run(["show",":"+path]).stdout;XCTAssertEqual(staged,bytes)}
            _=try await repo.abortRebase()
        }}
    }
}
