// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class SubmoduleAddRecoveryTests:XCTestCase {
    func fixture() async throws -> SSHTransportPreparationTests.Fixture {
        let value=try await SSHTransportPreparationTests().fixture()
        let command="exec '"+value.realGit.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        var script=try String(contentsOf:value.wrapper).replacingOccurrences(of:"|clone)",with:"|clone|submodule)")
        script=script.replacingOccurrences(of:command,with:command+" -c protocol.file.allow=always")
        script=script.replacingOccurrences(of:"#!/bin/sh\n",with:"""
        #!/bin/sh
        for argument do
          if [ "$argument" = remote.origin.turtlegitsshkeyfile ] && [ -f "$0.key-failure" ]; then
            printf '%s\\n' 'injected child key configuration failure' >&2
            exit 73
          fi
        done

        """)
        try script.write(to:value.wrapper,atomically:false,encoding:.utf8)
        try Data().write(to:URL(fileURLWithPath:value.wrapper.path+".key-failure"))
        return value
    }
    func added(_ fixture:SSHTransportPreparationTests.Fixture) async throws -> (SubmoduleAddOptions,SubmoduleAddReceipt) {
        var options=SubmoduleAddOptions();options.source=fixture.source.root.path;options.path="modules/recover ' 雪";options.sshKey=fixture.key
        do {_ = try await fixture.repo.addSubmoduleWithOutcome(options,prepareTransport:{_,token in try fixture.agent(token)});XCTFail("Injected configuration failure succeeded")}
        catch let failure as SubmoduleAddExecutionFailure {
            XCTAssertTrue(failure.outcome.attempted);XCTAssertTrue(failure.outcome.added);XCTAssertFalse(failure.outcome.configured)
            XCTAssertTrue(failure.outcome.output.contains("injected child key configuration failure"))
            XCTAssertEqual(failure.outcome.phase,.configuringKey);XCTAssertEqual((failure.underlying as? GitFailure)?.code,73)
            return (options,try XCTUnwrap(failure.outcome.receipt))
        }
        throw SubmoduleAddRecoveryFailure.replaced
    }
    func testPostAddKeyFailureRetriesConfigurationWithoutTransportAndPreservesIndex() async throws {
        let value=try await fixture();defer {try? FileManager.default.removeItem(at:value.root)}
        let (options,receipt)=try await added(value)
        let index=try Data(contentsOf:value.repo.root.appendingPathComponent(".git/index")),head=try await value.repo.run(["rev-parse","HEAD"]).stdout
        let cancelled=OperationCancellation();cancelled.cancel()
        do {_ = try await value.repo.retrySubmoduleAddKeyConfiguration(receipt,cancellation:cancelled);XCTFail("Cancelled recovery wrote config")} catch OperationCancellationFailure.cancelled {}
        do {_ = try await value.repo.retrySubmoduleAddKeyConfiguration(receipt);XCTFail("Repeated key failure succeeded")}
        catch let failure as SubmoduleAddExecutionFailure {XCTAssertTrue(failure.outcome.added);XCTAssertTrue(failure.outcome.output.contains("injected child key configuration failure"))}
        try FileManager.default.removeItem(at:URL(fileURLWithPath:value.wrapper.path+".key-failure"))
        let outcome=try await value.repo.retrySubmoduleAddKeyConfiguration(receipt)
        XCTAssertTrue(outcome.success && outcome.added && outcome.configured)
        let child=GitRepository(root:value.repo.root.appendingPathComponent(options.path),executable:value.realGit)
        let key=try await child.run(["config","--local","--get","remote.origin.turtlegitsshkeyfile"]).text
        XCTAssertEqual(key,value.key.path+"\n");XCTAssertEqual(try String(contentsOf:value.log),"submodule\n")
        XCTAssertEqual(try Data(contentsOf:value.repo.root.appendingPathComponent(".git/index")),index)
        let after=try await value.repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head)
    }
    func testRecoveryRejectsReplacedChildRepositoryWithoutChangingItsConfig() async throws {
        let value=try await fixture();defer {try? FileManager.default.removeItem(at:value.root)}
        let (options,receipt)=try await added(value)
        let otherRoot=value.root.appendingPathComponent("replacement");try FileManager.default.createDirectory(at:otherRoot,withIntermediateDirectories:true)
        let other=GitRepository(root:otherRoot,executable:value.realGit);_ = try await other.run(["init"])
        let before=try Data(contentsOf:otherRoot.appendingPathComponent(".git/config"))
        let gitFile=value.repo.root.appendingPathComponent(options.path).appendingPathComponent(".git"),originalGitFile=try Data(contentsOf:value.repo.root.appendingPathComponent(options.path).appendingPathComponent(".git"))
        try Data(("gitdir: "+otherRoot.appendingPathComponent(".git").path+"\n").utf8).write(to:gitFile)
        do {_ = try await value.repo.retrySubmoduleAddKeyConfiguration(receipt);XCTFail("Recovery retargeted a replaced checkout")} catch SubmoduleAddRecoveryFailure.replaced {}
        XCTAssertEqual(try Data(contentsOf:otherRoot.appendingPathComponent(".git/config")),before)
        try originalGitFile.write(to:gitFile)
        try FileManager.default.moveItem(at:receipt.gitDirectory,to:receipt.gitDirectory.appendingPathExtension("saved"))
        try FileManager.default.copyItem(at:otherRoot.appendingPathComponent(".git"),to:receipt.gitDirectory)
        do {_ = try await value.repo.retrySubmoduleAddKeyConfiguration(receipt);XCTFail("Recovery accepted a new repository at the same Git-directory path")} catch SubmoduleAddRecoveryFailure.replaced {}
        XCTAssertEqual(try Data(contentsOf:receipt.gitDirectory.appendingPathComponent("config")),before)
        XCTAssertEqual(try String(contentsOf:value.log),"submodule\n")
    }
}
