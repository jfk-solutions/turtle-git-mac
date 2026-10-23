import XCTest
@testable import TurtleGitCore

final class CommitPushContinuationTests:XCTestCase {
    private func mapped(_ plan:CommitPushContinuationPlan,file:StaticString=#filePath,line:UInt=#line)throws->PushOptions {
        guard case .push(let options)=plan else{XCTFail("Expected explicit source push mapping",file:file,line:line);throw PushValidationFailure.remote}
        return options
    }
    func testExplicitMappingPrecedenceRawDestinationAndNoSoleRemoteGuess()async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let bare=root.appendingPathComponent("private-origin.git")
        _=try await repo.run(["init","--bare","--template=",bare.path]);_=try await repo.run(["remote","add","origin",bare.path])
        let noMapping=try await repo.commitPushContinuationPlan()
        guard case .dialog=noMapping else{return XCTFail("Sole remote invented direct push authority")}
        _=try await repo.run(["config","branch.main.remote","origin"])
        let noDestination=try await repo.commitPushContinuationPlan()
        guard case .dialog=noDestination else{return XCTFail("Missing destination invented direct push")}
        _=try await repo.run(["config","branch.main.merge","refs/heads/tracked"])
        var options=try mapped(await repo.commitPushContinuationPlan())
        XCTAssertEqual(options.source,"main");XCTAssertEqual(options.remote,"origin");XCTAssertEqual(options.destination,"tracked")
        _=try await repo.run(["remote","add","global-push",bare.path]);_=try await repo.run(["remote","add","branch-push",bare.path])
        _=try await repo.run(["config","remote.pushdefault","global-push"])
        options=try mapped(await repo.commitPushContinuationPlan());XCTAssertEqual(options.remote,"global-push")
        _=try await repo.run(["config","branch.main.pushremote","branch-push"])
        _=try await repo.run(["config","branch.main.pushbranch","refs/for/main%topic=literal"])
        options=try mapped(await repo.commitPushContinuationPlan());XCTAssertEqual(options.remote,"branch-push");XCTAssertEqual(options.destination,"refs/for/main%topic=literal")
        XCTAssertFalse(options.force || options.forceWithLease || options.setUpstream || options.allBranches || options.allRemotes || options.includeTags || options.savePushBranch || options.savePushRemote || options.arbitraryURL)
        XCTAssertEqual(options.submodules,.none)
        let head=try await repo.rebaseCommit("HEAD").hash,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        _=try await repo.push(options)
        let delivered=try await repo.run(["--git-dir="+bare.path,"rev-parse","refs/for/main%topic=literal"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(delivered,head);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let merge=try await repo.run(["config","--get","branch.main.merge"]).text;XCTAssertEqual(merge,"refs/heads/tracked\n")
    }
    func testLocalDotMappingDetachedHeadAndCancelledResolution()async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=try await repo.run(["config","branch.main.remote","."]);_=try await repo.run(["config","branch.main.merge","refs/heads/local-result"])
        let options=try mapped(await repo.commitPushContinuationPlan())
        XCTAssertEqual(options.remote,".");XCTAssertEqual(options.destination,"local-result");XCTAssertTrue(options.arbitraryURL)
        _=try await repo.push(options)
        let head=try await repo.rebaseCommit("HEAD").hash,result=try await repo.rebaseCommit("refs/heads/local-result").hash;XCTAssertEqual(result,head)
        let token=OperationCancellation();token.cancel()
        do{_=try await repo.commitPushContinuationPlan(cancellation:token);XCTFail("Cancelled mapping accepted")}catch is OperationCancellationFailure{}
        _=try await repo.run(["checkout","--detach","HEAD"])
        let detached=try await repo.commitPushContinuationPlan(),detachedAmend=try await repo.commitPushContinuationPlan(usePushDialog:true)
        guard case .noBranch=detached else{return XCTFail("Detached Commit continuation invented branch mapping")}
        guard case .noBranch=detachedAmend else{return XCTFail("Detached amend bypassed source branch-first refusal")}
    }
}
