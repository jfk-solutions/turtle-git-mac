import XCTest
@testable import TurtleGitCore

private final class SetupTransferEvents:@unchecked Sendable {
    private let lock=NSLock()
    private var values:[GitTransferNotification]=[]
    func append(_ value:GitTransferNotification){lock.lock();values.append(value);lock.unlock()}
    var events:[GitTransferNotification]{lock.lock();defer{lock.unlock()};return values}
}

final class RepositorySetupAcceptanceTests:XCTestCase {
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func wrapper(_ root:URL,_ git:URL,_ body:String)throws->URL {
        let file=root.appendingPathComponent("setup-acceptance-git")
        try Data(("#!/bin/sh\n"+body+"\nexec "+quote(git.path)+" \"$@\"\n").utf8).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        return file
    }
    private func waitFor(_ file:URL)async throws {
        for _ in 0..<1000 {if FileManager.default.fileExists(atPath:file.path){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw NSError(domain:"RepositorySetupAcceptanceTests",code:1,userInfo:[NSLocalizedDescriptionKey:"Owned verification gate was not reached"])
    }

    func testCloneExitZeroReceiptSurvivesCancellationAndSkipsMutationRetry() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        var options=CloneOptions();options.source=root.path;options.noCheckout=true
        let destination=root.appendingPathComponent("accepted clone",isDirectory:true),token=OperationCancellation()
        let outcome=try await repo.cloneOutcome(options,to:destination,cancellation:token,onCommandFinished:{completion in
            XCTAssertTrue(completion.success);XCTAssertEqual(completion.exitCode,0);token.cancel()
        },backend:.init(enabled:false))
        XCTAssertTrue(outcome.verified);XCTAssertTrue(outcome.cancelledAfterCreation);XCTAssertFalse(outcome.configurationPending)
        XCTAssertEqual(outcome.repositoryRoot?.resolvingSymlinksInPath().path,destination.standardizedFileURL.resolvingSymlinksInPath().path)
        let recovered=try await repo.inspectCloneOutcome(outcome,at:destination)
        XCTAssertTrue(recovered.verified);XCTAssertTrue(recovered.cancelledAfterCreation);XCTAssertEqual(recovered.identity,outcome.identity)
        let target=GitRepository(root:destination,executable:repo.executable)
        let actual=try await target.run(["rev-parse","HEAD"]).stdout,original=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(actual,original)
        let cancelled=OperationCancellation();cancelled.cancel()
        do {_ = try await repo.cloneOutcome(options,to:root.appendingPathComponent("never-cloned"),cancellation:cancelled,backend:.init(enabled:false));XCTFail("Precommand cancel")}
        catch OperationCancellationFailure.cancelled {}
        do {_ = try await repo.cloneOutcome(options,to:destination,backend:.init(enabled:false));XCTFail("Existing clone is not proof that this command succeeded")}
        catch is GitFailure {}
    }

    func testCloneFailedVerificationIsAcceptedAndRecoveryNeverReclones() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let failure=root.appendingPathComponent("deny-inspection"),log=root.appendingPathComponent("clone-count")
        try Data().write(to:failure)
        let executable=try wrapper(root,repo.executable,"for argument in \"$@\"; do\n if [ \"$argument\" = clone ]; then printf 'clone\\n' >> "+quote(log.path)+"; fi\n if [ \"$argument\" = --is-bare-repository ] && [ -f "+quote(failure.path)+" ]; then echo 'private inspection failure' >&2; exit 7; fi\ndone")
        let runner=GitRepository(root:root,executable:executable,libgit2Configuration:.init(enabled:false))
        var options=CloneOptions();options.source=root.path
        let destination=root.appendingPathComponent("clone-inspection",isDirectory:true)
        let outcome=try await runner.cloneOutcome(options,to:destination,backend:.init(enabled:false))
        XCTAssertFalse(outcome.verified);XCTAssertNotNil(outcome.verificationError)
        XCTAssertTrue(FileManager.default.fileExists(atPath:destination.appendingPathComponent(".git").path))
        try FileManager.default.removeItem(at:failure)
        let recovered=try await runner.inspectCloneOutcome(outcome,at:destination)
        XCTAssertTrue(recovered.verified);XCTAssertNil(recovered.verificationError)
        XCTAssertEqual(try String(contentsOf:log),"clone\n")
    }

    func testExplicitCloneConfigurationRetryFencesAcceptedRepositoryIdentity() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        var options=CloneOptions();options.source=root.path
        let destination=root.appendingPathComponent("key-clone",isDirectory:true)
        let outcome=try await repo.cloneOutcome(options,to:destination,backend:.init(enabled:false))
        options.loadSSHKeyWithAgent=true;options.sshKey=root.appendingPathComponent("private key")
        let lock=destination.appendingPathComponent(".git/config.lock");try Data("foreign".utf8).write(to:lock)
        do {_ = try await repo.configureClonedRepository(options,at:destination,expected:outcome);XCTFail("Foreign config lock")}
        catch is GitFailure {}
        XCTAssertEqual(try Data(contentsOf:lock),Data("foreign".utf8));try FileManager.default.removeItem(at:lock)
        _ = try await repo.configureClonedRepository(options,at:destination,expected:outcome)
        let child=GitRepository(root:destination,executable:repo.executable)
        let key=try await child.run(["config","--local","--get","remote.origin.turtlegitsshkeyfile"]).stdout
        XCTAssertEqual(key,Data((options.sshKey!.path+"\n").utf8))
        let git=destination.appendingPathComponent(".git"),retained=destination.appendingPathComponent("original-git")
        try FileManager.default.moveItem(at:git,to:retained)
        _ = try await repo.run(["init","--",destination.path])
        let before=try Data(contentsOf:git.appendingPathComponent("config"))
        do {_ = try await repo.configureClonedRepository(options,at:destination,expected:outcome);XCTFail("Replacement repo must not receive old key")}
        catch InitializationFailure.destination {}
        XCTAssertEqual(try Data(contentsOf:git.appendingPathComponent("config")),before)
    }

    func testInitCancellationDuringFreshVerificationRetainsAcceptedRepository() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let reached=root.appendingPathComponent("init-inspection-entered"),release=root.appendingPathComponent("init-inspection-release")
        let executable=try wrapper(root,repo.executable,"for argument in \"$@\"; do\n if [ \"$argument\" = --is-bare-repository ]; then : > "+quote(reached.path)+"; while [ ! -f "+quote(release.path)+" ]; do sleep .01; done; fi\ndone")
        let runner=GitRepository(root:root,executable:executable),destination=root.appendingPathComponent("initialized.git",isDirectory:true),token=OperationCancellation()
        let task=Task {try await runner.initializeOutcome(at:destination,bare:true,cancellation:token)}
        do {
            try await waitFor(reached);token.cancel();try Data().write(to:release)
            let outcome=try await task.value
            XCTAssertTrue(outcome.verified);XCTAssertTrue(outcome.cancelledAfterCreation);XCTAssertEqual(outcome.isBare,true)
            let recovered=try await runner.inspectInitializationOutcome(outcome)
            XCTAssertEqual(recovered.identity,outcome.identity);XCTAssertTrue(recovered.verified)
        }catch {try? Data().write(to:release);_ = try? await task.value;throw error}
    }

    func testInitFailedInspectionRecoversReadOnlyAndNonzeroMutationStillFails() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let deny=root.appendingPathComponent("deny-init-inspection"),log=root.appendingPathComponent("init-count"),nonzero=root.appendingPathComponent("nonzero-init")
        try Data().write(to:deny)
        let executable=try wrapper(root,repo.executable,"for argument in \"$@\"; do\n if [ \"$argument\" = init ]; then printf 'init\\n' >> "+quote(log.path)+"; if [ -f "+quote(nonzero.path)+" ]; then "+quote(repo.executable.path)+" \"$@\"; exit 7; fi; fi\n if [ \"$argument\" = --is-bare-repository ] && [ -f "+quote(deny.path)+" ]; then exit 7; fi\ndone")
        let runner=GitRepository(root:root,executable:executable),destination=root.appendingPathComponent("init-inspection",isDirectory:true)
        let outcome=try await runner.initializeOutcome(at:destination,bare:false)
        XCTAssertFalse(outcome.verified);XCTAssertNotNil(outcome.verificationError)
        try FileManager.default.removeItem(at:deny)
        let recovered=try await runner.inspectInitializationOutcome(outcome)
        XCTAssertTrue(recovered.verified);XCTAssertEqual(try String(contentsOf:log),"init\n")
        try Data().write(to:nonzero)
        do {_ = try await runner.initializeOutcome(at:destination,bare:false);XCTFail("Nonzero init must fail even if repo exists")}
        catch let failure as GitFailure {XCTAssertEqual(failure.code,7)}
        let cancel=OperationCancellation();cancel.cancel()
        do {_ = try await runner.initializeOutcome(at:root.appendingPathComponent("never-initialized"),bare:false,cancellation:cancel);XCTFail("Precommand cancel")}
        catch OperationCancellationFailure.cancelled {}
    }

    func testSubmoduleAcceptedAddCancellationRetainsKeyOnlyRecoveryReceipt() async throws {
        let value=try await SubmoduleAddRecoveryTests().fixture();defer{try? FileManager.default.removeItem(at:value.root)}
        let reached=value.root.appendingPathComponent("submodule-inspection-entered"),release=value.root.appendingPathComponent("submodule-inspection-release")
        var script=try String(contentsOf:value.wrapper)
        script=script.replacingOccurrences(of:"#!/bin/sh\n",with:"#!/bin/sh\nfor argument in \"$@\"; do\n if [ \"$argument\" = --absolute-git-dir ]; then : > "+quote(reached.path)+"; while [ ! -f "+quote(release.path)+" ]; do sleep .01; done; fi\ndone\n")
        try script.write(to:value.wrapper,atomically:false,encoding:.utf8)
        var options=SubmoduleAddOptions();options.source=value.source.root.path;options.path="modules/accepted 雪";options.sshKey=value.key
        let token=OperationCancellation()
        let task=Task {try await value.repo.addSubmoduleWithOutcome(options,cancellation:token,prepareTransport:{_,token in try value.agent(token)})}
        do {
            try await waitFor(reached);token.cancel();try Data().write(to:release)
            let outcome=try await task.value
            XCTAssertTrue(outcome.added);XCTAssertTrue(outcome.verified);XCTAssertTrue(outcome.cancelled);XCTAssertFalse(outcome.configured)
            let receipt=try XCTUnwrap(outcome.receipt)
            let child=GitRepository(root:value.repo.root.appendingPathComponent(options.path),executable:value.realGit)
            let before=try await child.run(["config","--local","--get","remote.origin.turtlegitsshkeyfile"],successfulExitCodes:0...1)
            XCTAssertEqual(before.exitCode,1,"Canceled accepted Add must not configure key implicitly")
            let index=try Data(contentsOf:value.repo.root.appendingPathComponent(".git/index"))
            try FileManager.default.removeItem(at:URL(fileURLWithPath:value.wrapper.path+".key-failure"))
            let recovered=try await value.repo.retrySubmoduleAddKeyConfiguration(receipt)
            XCTAssertTrue(recovered.configured);XCTAssertEqual(try String(contentsOf:value.log),"submodule\n")
            XCTAssertEqual(try Data(contentsOf:value.repo.root.appendingPathComponent(".git/index")),index)
        }catch {try? Data().write(to:release);_ = try? await task.value;throw error}
    }

    func testSelectedLibgit2CloneRetainsAcceptedResultAndTransferNotifications() async throws {
        let backend=GitLibGit2Configuration(mask:2)
        do {guard try backend.executor(for:.clone) != nil else {throw XCTSkip("Selected libgit2 clone helper is unavailable")}}
        catch GitLibGit2Failure.runtimeMissing {throw XCTSkip("Selected libgit2 clone helper is unavailable")}
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let sourceHead=try await repo.run(["rev-parse","HEAD"]).stdout
        var options=CloneOptions();options.source=root.absoluteString
        let destination=root.appendingPathComponent("selected-helper-clone",isDirectory:true),token=OperationCancellation(),events=SetupTransferEvents()
        let outcome=try await repo.cloneOutcome(options,to:destination,cancellation:token,onCommandFinished:{receipt in
            XCTAssertTrue(receipt.success);XCTAssertEqual(receipt.exitCode,0);token.cancel()
        },backend:backend,onNotification:events.append)
        XCTAssertTrue(outcome.verified);XCTAssertTrue(outcome.cancelledAfterCreation)
        let expected=String(decoding:sourceHead,as:UTF8.self).trimmingCharacters(in:.newlines)
        XCTAssertTrue(events.events.contains {if case .reference(let update)=$0 {return update.reference=="refs/remotes/origin/main" && update.newHash==expected};return false})
        XCTAssertFalse(events.events.contains {if case .issue(let issue)=$0 {return !issue.commandSucceeded};return false})
    }

}
