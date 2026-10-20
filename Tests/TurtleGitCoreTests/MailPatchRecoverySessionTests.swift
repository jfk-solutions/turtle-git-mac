import XCTest
@testable import TurtleGitCore

final class MailPatchRecoverySessionTests: XCTestCase {
    private func fixture(twoPatches: Bool = false) async throws -> (URL, GitRepository, URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitAmReview-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var completed=false;defer{if !completed{try? FileManager.default.removeItem(at:root)}}
        let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_MAIL_TEST_GIT"] ?? "/usr/bin/git")
        let repo=GitRepository(root:root,executable:executable)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Recovery review"),("user.email","recovery@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        for name in ["first","second"] {try Data("base\n".utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage(["first","second"]);_=try await repo.commit(message:"Base")
        _=try await repo.run(["switch","-c","feature"])
        try Data("incoming first\n".utf8).write(to:root.appendingPathComponent("first"));try await repo.stage(["first"]);_=try await repo.commit(message:"First incoming patch")
        if twoPatches {try Data("incoming second\n".utf8).write(to:root.appendingPathComponent("second"));try await repo.stage(["second"]);_=try await repo.commit(message:"Second incoming patch")}
        let patch=root.appendingPathComponent("mailbox 雪.patch")
        try await repo.run(["format-patch",twoPatches ? "-2":"-1","--stdout","HEAD"]).stdout.write(to:patch)
        _=try await repo.run(["switch","main"])
        for name in ["first","second"] {try Data("local\n".utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage(["first","second"]);_=try await repo.commit(message:"Conflicting local changes")
        do{_=try await repo.importMailPatch(patch);XCTFail("Fixture must stop at an actual am conflict")}catch is GitFailure{}
        completed=true;return(root,repo,patch)
    }
    private func capture(_ repo:GitRepository)async throws->MailPatchRecoverySession {
        let value=try await repo.mailPatchRecoverySession();return try XCTUnwrap(value)
    }
    private func assertChanged(_ repo:GitRepository,_ review:MailPatchRecoverySession,action:MailPatchRecovery = .abort)async throws {
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["ls-files","--stage","-z"]).stdout
        do{_=try await repo.recoverMailPatch(action,reviewed:review);XCTFail("Stale recovery operated on another session/item")}
        catch MailPatchFailure.changedSession{}
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertEqual(afterHead,head);XCTAssertEqual(afterIndex,index)
    }

    func testReviewedAbortSkipAndResolvedAllowConflictResolutionAndStaging()async throws {
        for action in MailPatchRecovery.allCases {
            let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            let before=try await repo.run(["rev-parse","HEAD"]).stdout,review=try await capture(repo)
            XCTAssertEqual(review.currentItem,1);XCTAssertEqual(review.totalItems,1)
            XCTAssertTrue(review.metadataPath.hasSuffix("/rebase-apply"))
            if action == .resolved {
                try Data("resolved manually\n".utf8).write(to:root.appendingPathComponent("first"));try await repo.stage(["first"])
                let stagedReview=try await capture(repo)
                XCTAssertEqual(stagedReview,review,"Normal conflict resolution must not invalidate the reviewed session")
            }
            _=try await repo.recoverMailPatch(action,reviewed:review)
            let session=try await repo.mailPatchSession(),remaining=try await repo.mailPatchRecoverySession(),head=try await repo.run(["rev-parse","HEAD"]).stdout
            XCTAssertEqual(session,.none);XCTAssertNil(remaining)
            if action == .resolved {XCTAssertNotEqual(head,before);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("first")),Data("resolved manually\n".utf8))}
            else{XCTAssertEqual(head,before);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("first")),Data("local\n".utf8))}
        }
    }

    func testIdenticalReplacementSessionRefusesEveryOldRecoveryChoice()async throws {
        let(root,repo,patch)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let original=try await capture(repo)
        _=try await repo.recoverMailPatch(.abort,reviewed:original)
        do{_=try await repo.importMailPatch(patch);XCTFail("Expected replacement conflict")}catch is GitFailure{}
        let replacement=try await capture(repo)
        XCTAssertEqual(replacement.metadataPath,original.metadataPath);XCTAssertEqual(replacement.currentItem,original.currentItem)
        XCTAssertNotEqual(replacement,original,"Directory incarnation must distinguish otherwise identical am sessions")
        for action in MailPatchRecovery.allCases {try await assertChanged(repo,original,action:action);let current=try await capture(repo);XCTAssertEqual(current,replacement)}
        _=try await repo.recoverMailPatch(.abort,reviewed:replacement)
    }

    func testExternallyAdvancedMailboxRequiresAnotherReview()async throws {
        let(root,repo,_)=try await fixture(twoPatches:true);defer{try? FileManager.default.removeItem(at:root)}
        let first=try await capture(repo);XCTAssertEqual(first.currentItem,1);XCTAssertEqual(first.totalItems,2)
        do{_=try await repo.run(["am","--skip"]);XCTFail("Second patch must also conflict")}catch is GitFailure{}
        let second=try await capture(repo);XCTAssertEqual(second.currentItem,2);XCTAssertNotEqual(second,first)
        try await assertChanged(repo,first)
        let retained=try await capture(repo);XCTAssertEqual(retained,second)
        _=try await repo.recoverMailPatch(.abort,reviewed:second)
    }

    func testFailedResolvedRetainsReviewAndExplicitRetryCanSucceed()async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let review=try await capture(repo)
        do{_=try await repo.recoverMailPatch(.resolved,reviewed:review);XCTFail("Unresolved index should refuse recovery")}catch is GitFailure{}
        let afterFailure=try await capture(repo);XCTAssertEqual(afterFailure,review)
        try Data("resolved after error\n".utf8).write(to:root.appendingPathComponent("first"));try await repo.stage(["first"])
        _=try await repo.recoverMailPatch(.resolved,reviewed:review)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("first")),Data("resolved after error\n".utf8))
        let session=try await repo.mailPatchSession();XCTAssertEqual(session,.none)
    }

    func testCancellationAndRemovedSessionNeverRunReviewedRecovery()async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let review=try await capture(repo),cancelled=OperationCancellation();cancelled.cancel()
        do{_=try await repo.mailPatchRecoverySession(cancellation:cancelled);XCTFail("Cancelled capture ran")}catch OperationCancellationFailure.cancelled{}
        for action in MailPatchRecovery.allCases {
            do{_=try await repo.recoverMailPatch(action,reviewed:review,cancellation:cancelled);XCTFail("Cancelled recovery ran")}catch OperationCancellationFailure.cancelled{}
            let afterCancellation=try await capture(repo);XCTAssertEqual(afterCancellation,review)
        }
        _=try await repo.recoverMailPatch(.abort,reviewed:review)
        try await assertChanged(repo,review)
        do{_=try await repo.recoverMailPatch(.abort);XCTFail("Legacy empty-session recovery ran")}catch MailPatchFailure.noSession{}
    }

    func testExternalCommitAndChangedSessionMetadataRequireNewReview()async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let review=try await capture(repo)
        try Data("external resolution\n".utf8).write(to:root.appendingPathComponent("first"));try await repo.stage(["first"])
        _=try await repo.commit(message:"External commit while recovery question is open")
        try await assertChanged(repo,review)
        let fresh=try await capture(repo)
        let marker=FileTransferPaths.fileURL(fresh.metadataPath+"/original-commit")
        let existing=try? Data(contentsOf:marker)
        try Data("changed-current-patch-identity\n".utf8).write(to:marker)
        try await assertChanged(repo,fresh)
        if let existing{try existing.write(to:marker)}else{try FileManager.default.removeItem(at:marker)}
        _=try await repo.recoverMailPatch(.abort,reviewed:try await capture(repo))
    }

    func testLinkedWorktreeCannotConsumeAnotherWorktreesReview()async throws {
        let(root,repo,patch)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let parent=try await capture(repo),linkedRoot=root.appendingPathComponent("linked checkout",isDirectory:true)
        _=try await repo.run(["worktree","add","--detach",linkedRoot.path,"HEAD"])
        let linked=GitRepository(root:linkedRoot,executable:await repo.executable)
        do{_=try await linked.importMailPatch(patch);XCTFail("Expected linked worktree conflict")}catch is GitFailure{}
        let child=try await capture(linked)
        XCTAssertNotEqual(child.metadataPath,parent.metadataPath)
        XCTAssertEqual(child.currentItem,parent.currentItem)
        try await assertChanged(linked,parent)
        let unchangedParent=try await capture(repo),unchangedChild=try await capture(linked)
        XCTAssertEqual(unchangedParent,parent);XCTAssertEqual(unchangedChild,child)
        _=try await linked.recoverMailPatch(.abort,reviewed:child)
        _=try await repo.recoverMailPatch(.abort,reviewed:parent)
    }
}
