import XCTest
@testable import TurtleGitCore

final class CreationAcceptanceTests:XCTestCase {
    private func quoted(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func wrapper(root:URL,git:URL,body:String)throws->URL {
        let url=root.appendingPathComponent("acceptance-git")
        try Data(("#!/bin/sh\n"+body+"\nexec "+quoted(git.path)+" \"$@\"\n").utf8).write(to:url)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:url.path)
        return url
    }
    private func waitFor(_ file:URL)async throws {
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath:file.path){return}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        throw NSError(domain:"CreationAcceptanceTests",code:1,userInfo:[NSLocalizedDescriptionKey:"Owned verification gate was not reached"])
    }

    func testOnlyExitZeroCancellationResultRetainsActualAcceptedOutput() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let result=try await repo.run(["branch","accepted-result","HEAD"])
        let recovered=try acceptedCreationResult {throw GitCommandCancellationFailure(result:result)}
        XCTAssertEqual(recovered.exitCode,0);XCTAssertEqual(recovered.stdout,result.stdout);XCTAssertEqual(recovered.stderr,result.stderr)
        let bad=try await repo.run(["branch","accepted-result","HEAD"],successfulExitCodes:0...128)
        XCTAssertNotEqual(bad.exitCode,0)
        XCTAssertThrowsError(try acceptedCreationResult {throw GitCommandCancellationFailure(result:bad)}) {XCTAssertTrue($0 is GitCommandCancellationFailure)}
        XCTAssertThrowsError(try acceptedCreationResult {throw OperationCancellationFailure.cancelled}) {XCTAssertTrue($0 is OperationCancellationFailure)}
    }

    func testBranchCancellationAfterExitZeroUsesFreshVerificationAndNeverWritesDescription() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let reached=root.appendingPathComponent("verify-entered"),release=root.appendingPathComponent("verify-release")
        let executable=try wrapper(root:root,git:repo.executable,body:"for argument in \"$@\"; do\n if [ \"$argument\" = show-ref ]; then\n  : > "+quoted(reached.path)+"\n  while [ ! -f "+quoted(release.path)+" ]; do sleep .01; done\n fi\ndone")
        let gated=GitRepository(root:root,executable:executable,libgit2Configuration:.init(enabled:false))
        var options=ReferenceCreationOptions();options.name="accepted-branch";options.message="separate description"
        let plan=try await repo.prepareReferenceCreation(options),token=OperationCancellation()
        let task=Task {try await gated.createReferenceAccepted(plan,cancellation:token)}
        do {
            try await waitFor(reached);token.cancel();try Data().write(to:release)
            let receipt=try await task.value
            XCTAssertTrue(receipt.verified);XCTAssertTrue(receipt.cancelledAfterCreation)
            XCTAssertEqual(receipt.reference,"refs/heads/accepted-branch")
            let current=try await repo.run(["rev-parse","refs/heads/accepted-branch"]).text.trimmingCharacters(in:.newlines)
            XCTAssertEqual(receipt.actualObjectID,current);XCTAssertEqual(receipt.peeledObjectID,current)
            let description=try await repo.run(["config","--get","branch.accepted-branch.description"],successfulExitCodes:0...1)
            XCTAssertEqual(description.exitCode,1)
        }catch {
            try? Data().write(to:release);_ = try? await task.value;throw error
        }
    }

    func testRemoteMovementAndAnnotatedTagRecordActualDirectAndPeeledIdentity() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["remote","add","origin",root.path]);_ = try await repo.run(["update-ref","refs/remotes/origin/moving","HEAD"])
        var branch=ReferenceCreationOptions();branch.name="moved-base";branch.revision="refs/remotes/origin/moving"
        let plan=try await repo.prepareReferenceCreation(branch)
        _ = try await repo.run(["commit","--allow-empty","-m","new remote base"]);_ = try await repo.run(["update-ref","refs/remotes/origin/moving","HEAD"])
        let receipt=try await repo.createReferenceAccepted(plan)
        XCTAssertTrue(receipt.verified);XCTAssertNotEqual(receipt.actualObjectID,plan.resolvedHash)
        var tag=ReferenceCreationOptions();tag.name="annotated";tag.isTag=true;tag.message="release"
        let tagPlan=try await repo.prepareReferenceCreation(tag)
        let annotated=try await repo.createReferenceAccepted(tagPlan)
        XCTAssertTrue(annotated.verified);XCTAssertNotEqual(annotated.actualObjectID,annotated.peeledObjectID)
        XCTAssertEqual(annotated.peeledObjectID,tagPlan.resolvedHash)
    }

    func testFailedVerificationRetainsAcceptanceAndDescriptionFailureCarriesReceipt() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let executable=try wrapper(root:root,git:repo.executable,body:"for argument in \"$@\"; do\n if [ \"$argument\" = show-ref ]; then echo 'private verification failure' >&2; exit 7; fi\ndone")
        let failing=GitRepository(root:root,executable:executable,libgit2Configuration:.init(enabled:false))
        var options=ReferenceCreationOptions();options.name="created-unverified"
        let plan=try await repo.prepareReferenceCreation(options)
        let receipt=try await failing.createReferenceAccepted(plan)
        XCTAssertFalse(receipt.verified);XCTAssertNil(receipt.actualObjectID);XCTAssertNotNil(receipt.verificationError)
        let exists=try await repo.run(["show-ref","--verify","refs/heads/created-unverified"])
        XCTAssertEqual(exists.exitCode,0)
        options.name="created-before-description";options.message="description"
        let lock=root.appendingPathComponent(".git/config.lock");try Data("foreign".utf8).write(to:lock)
        do {_ = try await repo.createReference(options);XCTFail("Description lock should fail")}
        catch let failure as ReferenceCreationPostCreationFailure {
            XCTAssertTrue(failure.receipt.verified);XCTAssertEqual(failure.receipt.reference,"refs/heads/created-before-description")
        }
        XCTAssertEqual(try Data(contentsOf:lock),Data("foreign".utf8))
    }

    func testWorktreeAcceptedIdentityAndPrecommandCancellationPreserveExistingState() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let destination=root.appendingPathComponent("linked worktree",isDirectory:true)
        var options=WorktreeCreationOptions();options.detach=true;options.checkout=false
        let receipt=try await repo.createWorktreeAccepted(at:destination,options:options)
        XCTAssertTrue(receipt.verified);XCTAssertTrue(receipt.worktree?.isDetached == true)
        XCTAssertEqual(receipt.worktree?.path.resolvingSymlinksInPath().path,destination.standardizedFileURL.resolvingSymlinksInPath().path)
        let before=try await repo.run(["worktree","list","--porcelain","-z"]).stdout
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.createWorktreeAccepted(at:root.appendingPathComponent("never-created"),cancellation:token);XCTFail("Precommand cancel")}
        catch OperationCancellationFailure.cancelled {}
        let after=try await repo.run(["worktree","list","--porcelain","-z"]).stdout
        XCTAssertEqual(before,after)
        do {_ = try await repo.createWorktreeAccepted(at:destination,options:options);XCTFail("Existing target must fail")}
        catch is GitFailure {}
    }

    func testWorktreeCancellationDuringFreshReadRetainsRegisteredAcceptedWorktree() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let reached=root.appendingPathComponent("worktree-verify-entered"),release=root.appendingPathComponent("worktree-verify-release")
        let executable=try wrapper(root:root,git:repo.executable,body:"for argument in \"$@\"; do\n if [ \"$argument\" = list ]; then\n  : > "+quoted(reached.path)+"\n  while [ ! -f "+quoted(release.path)+" ]; do sleep .01; done\n fi\ndone")
        let gated=GitRepository(root:root,executable:executable,libgit2Configuration:.init(enabled:false))
        var options=WorktreeCreationOptions();options.detach=true
        let destination=root.appendingPathComponent("accepted-linked",isDirectory:true),token=OperationCancellation()
        let task=Task {try await gated.createWorktreeAccepted(at:destination,options:options,cancellation:token)}
        do {
            try await waitFor(reached);token.cancel();try Data().write(to:release)
            let receipt=try await task.value
            XCTAssertTrue(receipt.verified);XCTAssertTrue(receipt.cancelledAfterCreation)
            XCTAssertEqual(receipt.worktree?.path.resolvingSymlinksInPath().path,destination.standardizedFileURL.resolvingSymlinksInPath().path)
        }catch {try? Data().write(to:release);_ = try? await task.value;throw error}
    }

    func testNonzeroMutationIsNeverPromotedByAnExistingReference() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let executable=try wrapper(root:root,git:repo.executable,body:"for argument in \"$@\"; do\n if [ \"$argument\" = branch ]; then "+quoted(repo.executable.path)+" \"$@\"; result=$?; if [ \"$result\" = 0 ]; then exit 7; else exit \"$result\"; fi; fi\ndone")
        let failing=GitRepository(root:root,executable:executable,libgit2Configuration:.init(enabled:false))
        var options=ReferenceCreationOptions();options.name="exists-after-failure"
        let plan=try await failing.prepareReferenceCreation(options)
        do {_ = try await failing.createReferenceAccepted(plan);XCTFail("Nonzero mutation must remain failure")}
        catch let failure as GitFailure {XCTAssertEqual(failure.code,7)}
        let exists=try await repo.run(["show-ref","--verify","refs/heads/exists-after-failure"])
        XCTAssertEqual(exists.exitCode,0,"Existence alone is deliberately insufficient to accept a failed command")
    }


    func testSuccessfulWarningsNeverBecomeReferenceObjectIdentity() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let executable=try wrapper(root:root,git:repo.executable,body:"printf 'warning: private successful diagnostic\\n' >&2")
        let warning=GitRepository(root:root,executable:executable,libgit2Configuration:.init(enabled:false))
        var options=ReferenceCreationOptions();options.name="warning-receipt";options.isTag=true;options.message="annotated"
        let plan=try await warning.prepareReferenceCreation(options)
        let receipt=try await warning.createReferenceAccepted(plan)
        XCTAssertTrue(receipt.verified);XCTAssertNil(receipt.verificationError)
        XCTAssertTrue(receipt.output.contains("warning: private successful diagnostic"))
        XCTAssertEqual(receipt.verificationDiagnostics.components(separatedBy:"warning: private successful diagnostic").count-1,2)
        let actual=try await repo.run(["rev-parse","refs/tags/warning-receipt"]).stdout
        let peeled=try await repo.run(["rev-parse","refs/tags/warning-receipt^{}"]).stdout
        XCTAssertEqual(receipt.actualObjectID,String(decoding:actual,as:UTF8.self).trimmingCharacters(in:.newlines))
        XCTAssertEqual(receipt.peeledObjectID,String(decoding:peeled,as:UTF8.self).trimmingCharacters(in:.newlines))
        XCTAssertNotEqual(receipt.actualObjectID,receipt.peeledObjectID)
    }

}
