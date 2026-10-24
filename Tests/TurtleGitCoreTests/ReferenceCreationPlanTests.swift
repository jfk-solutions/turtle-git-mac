// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class ReferenceCreationPlanTests:XCTestCase {
    private func fixture()async throws->(GitRepository,String) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("ReferencePlan-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let git=ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map{URL(fileURLWithPath:$0)} ?? URL(fileURLWithPath:"/usr/bin/git"),repo=GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false))
        _ = try await repo.run(["init","-b","main"])
        for(key,value)in[("user.name","Plan QA"),("user.email","plan@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        return(repo,try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines))
    }
    func testPreparedBranchIsReadOnlyAndPinsValidatedObjectAndNormalizedOptions()async throws {
        let(repo,base)=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let refs=try await repo.run(["show-ref"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:repo.root.appendingPathComponent(".git/config"))
        var options=ReferenceCreationOptions();options.name="  topic  ";options.message="  first\r\nsecond  "
        let plan=try await repo.prepareReferenceCreation(options)
        XCTAssertEqual(plan.options.name,"topic");XCTAssertEqual(plan.options.message,"first\nsecond");XCTAssertEqual(plan.resolvedHash,base)
        XCTAssertEqual(plan.arguments,["branch","--no-track","--","topic",base])
        let preparedRefs=try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(preparedRefs,refs);XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),index);XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent(".git/config")),config)
        _ = try await repo.run(["commit","--allow-empty","-m","advanced after plan"])
        _ = try await repo.createReference(plan,writeDescription:false)
        let actual=try await repo.run(["rev-parse","refs/heads/topic"]).text.trimmingCharacters(in:.newlines),description=try await repo.run(["config","--get","branch.topic.description"],successfulExitCodes:0...1)
        XCTAssertEqual(actual,base);XCTAssertEqual(description.exitCode,1)
        try await repo.updateBranchDescription("topic",message:plan.options.message,expectedHash:plan.resolvedHash)
        let written=try await repo.run(["config","--get","branch.topic.description"]).text
        XCTAssertEqual(written,"first\nsecond\n")
        // The source tests the raw description before trimming: an explicit
        // whitespace-only description on Force means clear the old config.
        var clearing=ReferenceCreationOptions();clearing.name="topic";clearing.force=true;clearing.message=" \r\n\t "
        let clearPlan=try await repo.prepareReferenceCreation(clearing)
        XCTAssertEqual(clearPlan.options.message,"")
        _ = try await repo.createReference(clearPlan)
        let cleared=try await repo.run(["config","--get","branch.topic.description"],successfulExitCodes:0...1)
        XCTAssertEqual(cleared.exitCode,1,"Normalized whitespace lost the source request to clear the old branch description")
    }
    func testPreparedAnnotatedTagKeepsCapturedMessageAndUncheckedSigning()async throws {
        let(repo,base)=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        _ = try await repo.run(["config","tag.gpgSign","true"])
        var options=ReferenceCreationOptions();options.isTag=true;options.name="release";options.message="  release\r\n雪  "
        let plan=try await repo.prepareReferenceCreation(options)
        XCTAssertEqual(plan.arguments,["-c","tag.gpgSign=false","tag","--no-sign","--annotate","--message","release\n雪","--","release",base])
        options.name="later";options.message="later message";options.sign=true
        _ = try await repo.run(["commit","--allow-empty","-m","advance"])
        _ = try await repo.createReference(plan)
        let target=try await repo.run(["rev-parse","refs/tags/release^{}"]).text.trimmingCharacters(in:.newlines),tag=try await repo.run(["cat-file","-p","refs/tags/release"]).text
        XCTAssertEqual(target,base);XCTAssertTrue(tag.hasSuffix("\nrelease\n雪\n"));XCTAssertFalse(tag.contains("BEGIN PGP SIGNATURE"))
        let late=try await repo.run(["show-ref","--verify","--quiet","refs/tags/later"],successfulExitCodes:0...1);XCTAssertEqual(late.exitCode,1)
    }
    func testRejectedValidationCrossNameAndPerformRacePreserveReferences()async throws {
        let(repo,base)=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        _ = try await repo.run(["tag","--no-sign","shared",base])
        let original=try await repo.run(["show-ref"]).stdout
        var signedInvalid=ReferenceCreationOptions();signedInvalid.isTag=true;signedInvalid.sign=true;signedInvalid.name="--bad"
        do {_ = try await repo.prepareReferenceCreationForm(signedInvalid);XCTFail("Signed empty message accepted")}
        catch ReferenceCreationFailure.signingMessageRequired {} // Source OnOK checks this before the name.
        for(name,revision,sign,message)in[("--bad","HEAD",false,""),("valid","missing",false,""),("signed","HEAD",true,"")] {
            var options=ReferenceCreationOptions();options.name=name;options.revision=revision;options.isTag=sign;options.sign=sign;options.message=message
            do{_ = try await repo.prepareReferenceCreation(options);XCTFail("Invalid plan accepted")}catch is ReferenceCreationFailure{}
        }
        var acceptedForm=ReferenceCreationOptions();acceptedForm.name="form-valid";acceptedForm.revision="missing-reference"
        let form=try await repo.prepareReferenceCreationForm(acceptedForm)
        XCTAssertEqual(form.options.revision,"missing-reference","Source form acceptance must precede base resolution")
        do{_ = try await repo.prepareReferenceCreation(form);XCTFail("Invalid accepted base resolved")}catch ReferenceCreationFailure.invalidRevision{}
        var conflict=ReferenceCreationOptions();conflict.name="shared"
        do{_ = try await repo.prepareReferenceCreation(conflict);XCTFail("Cross-name collision did not require Continue")}catch ReferenceCreationFailure.nameConflict{}
        let rejected=try await repo.run(["show-ref"]).stdout;XCTAssertEqual(rejected,original)
        conflict.allowNameConflict=true;let accepted=try await repo.prepareReferenceCreation(conflict)
        let afterPrepare=try await repo.run(["show-ref"]).stdout;XCTAssertEqual(afterPrepare,original)
        _ = try await repo.run(["commit","--allow-empty","-m","other"])
        _ = try await repo.run(["branch","shared","HEAD"])
        let competing=try await repo.run(["rev-parse","refs/heads/shared"]).stdout
        do{_ = try await repo.createReference(accepted);XCTFail("Non-force perform overwrote competing ref")}catch{}
        let retained=try await repo.run(["rev-parse","refs/heads/shared"]).stdout;XCTAssertEqual(retained,competing)
        let cancelled=OperationCancellation();cancelled.cancel()
        do{_ = try await repo.createReference(accepted,cancellation:cancelled);XCTFail("Precancelled plan executed")}catch OperationCancellationFailure.cancelled{}
        let final=try await repo.run(["rev-parse","refs/heads/shared"]).stdout;XCTAssertEqual(final,competing)
    }
    func testRemotePlanPreservesGitTrackingAndRejectsOtherRepository()async throws {
        let(repo,base)=try await fixture(),(other,_)=try await fixture()
        defer{try? FileManager.default.removeItem(at:repo.root);try? FileManager.default.removeItem(at:other.root)}
        _ = try await repo.run(["remote","add","origin",repo.root.path])
        _ = try await repo.run(["update-ref","refs/remotes/origin/topic",base])
        var options=ReferenceCreationOptions();options.name="tracked";options.revision="refs/remotes/origin/topic";options.tracking = .track
        let plan=try await repo.prepareReferenceCreation(options)
        XCTAssertEqual(plan.arguments,["branch","--track","--","tracked","refs/remotes/origin/topic"]);XCTAssertEqual(plan.resolvedHash,base)
        do{_ = try await other.createReference(plan);XCTFail("Prepared plan crossed repository identity")}catch ReferenceCreationFailure.preparedRepositoryMismatch{}
        _ = try await repo.run(["commit","--allow-empty","-m","remote moved"])
        let current=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-ref","refs/remotes/origin/topic",current])
        _ = try await repo.createReference(plan)
        let target=try await repo.run(["rev-parse","refs/heads/tracked"]).text.trimmingCharacters(in:.newlines),remote=try await repo.run(["config","--get","branch.tracked.remote"]).text,merge=try await repo.run(["config","--get","branch.tracked.merge"]).text
        XCTAssertEqual(target,current,"Remote plans retain Git tracking/ref-name semantics rather than a new target-CAS policy")
        XCTAssertEqual(remote,"origin\n");XCTAssertEqual(merge,"refs/heads/topic\n")
    }

}
