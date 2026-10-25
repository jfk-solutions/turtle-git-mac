import XCTest
@testable import TurtleGitCore

final class RebaseAmendRecoveryTests:XCTestCase {
    var editor:URL {RebaseTests().editor}
    struct Fixture {
        let root:URL,repository:GitRepository,originalHead:String,head:LogEntry,state:RebaseState
    }
    func fixture(squash:Bool=false,cherry:Bool=false,nextSquash:Bool=false)async throws->Fixture {
        let(root,original,_)=try await RebaseTests().fixture()
        var accepted=false;defer {if !accepted {try? FileManager.default.removeItem(at:root)}}
        let repository=GitRepository(root:root,executable:original.executable,libgit2Configuration:.init(enabled:false))
        _=try await repository.run(["config","core.hooksPath","/dev/null"])
        var plan=try await repository.rebasePlan(RebaseTests().options())
        let originalHead=plan.branchHash
        if cherry {
            let hashes=plan.entries.map { $0.commit.hash }
            _=try await repository.run(["switch","upstream"])
            plan=try await repository.cherryPickPlan(revisions:hashes)
        }
        plan.entries[squash ? 1:0].action=squash ? .squash:.edit
        var stopped=try await repository.startRebase(plan,editorExecutable:editor)
        XCTAssertTrue(stopped.state.active)
        if squash {XCTAssertNotNil(stopped.state.squashMessage)} else {XCTAssertTrue(stopped.state.isEditPause)}
        if nextSquash {
            let snapshot=try await repository.rebaseActionEditSnapshot()
            let next=try XCTUnwrap(snapshot.replay.first {$0.progress == .pending})
            let updated=try await repository.changePendingRebaseActions(.squash,ids:[next.id],expected:snapshot,editorExecutable:editor)
            stopped=RebaseExecution(output:stopped.output,exitCode:stopped.exitCode,state:updated.state)
        }
        let head=try await repository.rebaseCommit("HEAD")
        accepted=true;return .init(root:root,repository:repository,originalHead:originalHead,head:head,state:stopped.state)
    }
    func hook(_ f:Fixture)async throws->URL {
        let hooks=f.root.appendingPathComponent(".git/owned-failing-hooks",isDirectory:true)
        try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:true)
        let file=hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\nprintf 'attempt\\n' >> \"$(dirname \"$0\")/attempts\"\nprintf 'Owned message commit refused\\n' >&2\nexit 73\n".utf8).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
        _=try await f.repository.run(["config","core.hooksPath",hooks.path])
        return hooks.appendingPathComponent("attempts")
    }
    func attempts(_ path:URL)->Int {(try? String(contentsOf:path,encoding:.utf8).split(separator:"\n").count) ?? 0}
    func fail(_ repository:GitRepository,message:String,squash:Bool=false)async throws->RebaseCleanCommitFailure {
        do {
            _=try await repository.continueRebase(squashMessage:squash ? message:nil,editMessage:squash ? nil:message,editorExecutable:editor)
            XCTFail("Expected a clean stopped message failure");throw RebaseFailure.plan
        } catch let failure as RebaseCleanCommitFailure {return failure}
    }
    func testRetryReopensAndCannotSilentlyRerunBeforeCheckedRelease()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let calls=try await hook(f),failure=try await fail(f.repository,message:"Retained draft 🐢\n\nbody")
        XCTAssertEqual(attempts(calls),1);XCTAssertEqual(failure.head,f.head.hash);XCTAssertTrue(failure.diagnostic.contains("Owned message commit refused"))
        let reopened=GitRepository(root:f.root,executable:f.repository.executable,libgit2Configuration:.init(enabled:false))
        let saved=try await reopened.rebaseState()
        XCTAssertEqual(saved.cleanCommitFailure,failure);XCTAssertFalse(saved.canSplit)
        do {_=try await reopened.continueRebase(editMessage:"other");XCTFail("Pending receipt bypassed")} catch let actual as RebaseCleanCommitFailure {XCTAssertEqual(actual.id,failure.id)}
        XCTAssertEqual(attempts(calls),1)
        do {_=try await reopened.beginRebaseSplit();XCTFail("Pending recovery split")}catch RebaseFailure.plan {}
        do {_=try await reopened.rebaseActionEditSnapshot();XCTFail("Pending recovery plan edit")}catch RebaseFailure.changed {}
        let retry=try await reopened.retryRebaseCleanCommitFailure(failure,expected:saved,expectedHead:failure.head)
        XCTAssertNil(retry.cleanCommitFailure);XCTAssertTrue(retry.isEditPause);XCTAssertEqual(attempts(calls),1)
        _=try await reopened.run(["config","core.hooksPath","/dev/null"])
        let finished=try await reopened.continueRebase(editMessage:failure.message,expectedReplayState:retry,expectedReplayHead:failure.head,editorExecutable:editor)
        XCTAssertFalse(finished.state.active)
        let edited=try await reopened.rebaseCommit("HEAD~1")
        XCTAssertEqual(edited.subject,"Retained draft 🐢");XCTAssertEqual(edited.author,f.head.author);XCTAssertEqual(edited.date,f.head.date)
    }
    func testIgnoreUsesActualHeadAndNeverRerunsFailedCommitForRebaseOrCherryPick()async throws {
        for cherry in [false,true] {
            let f=try await fixture(cherry:cherry);defer {try? FileManager.default.removeItem(at:f.root)}
            let calls=try await hook(f),failure=try await fail(f.repository,message:"Must not be committed")
            let saved=try await f.repository.rebaseState()
            let finished=try await f.repository.ignoreRebaseCleanCommitFailure(failure,expected:saved,expectedHead:failure.head,editorExecutable:editor)
            XCTAssertFalse(finished.state.active);XCTAssertEqual(attempts(calls),1)
            let kept=try await f.repository.rebaseCommit("HEAD~1")
            XCTAssertEqual(kept.hash,f.head.hash);XCTAssertEqual(kept.message,f.head.message);XCTAssertEqual(kept.parents,f.head.parents)
            XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("second.txt").path))
        }
    }
    func testIgnoredEditBeforeSquashRetainsRequestedAccumulatorAndActualFirstAuthor()async throws {
        let f=try await fixture(nextSquash:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let calls=try await hook(f),draft="Requested first subject\n\nOnly requested body 🐢"
        let failure=try await fail(f.repository,message:draft),saved=try await f.repository.rebaseState()
        let next=try await f.repository.ignoreRebaseCleanCommitFailure(failure,expected:saved,expectedHead:failure.head,editorExecutable:editor)
        XCTAssertNotNil(next.state.squashMessage);XCTAssertEqual(attempts(calls),1)
        let accumulated=try XCTUnwrap(next.state.squashMessage?.message)
        XCTAssertTrue(accumulated.contains(draft));XCTAssertEqual(accumulated.components(separatedBy:"Only requested body 🐢").count-1,1)
        XCTAssertFalse(accumulated.hasPrefix(f.head.subject+"\n"));XCTAssertTrue(accumulated.contains("second"))
        _=try await f.repository.run(["config","core.hooksPath","/dev/null"])
        let done=try await f.repository.continueRebase(squashMessage:accumulated,editorExecutable:editor)
        XCTAssertFalse(done.state.active)
        let combined=try await f.repository.rebaseCommit("HEAD")
        XCTAssertEqual(combined.author,f.head.author);XCTAssertEqual(combined.email,f.head.email);XCTAssertEqual(combined.date,f.head.date)
        XCTAssertEqual(combined.message.components(separatedBy:"Only requested body 🐢").count-1,1)
    }
    func testCleanSquashFailureIgnoreKeepsActualCommitAndAbortRestoresOriginalBranch()async throws {
        let f=try await fixture(squash:true);defer {try? FileManager.default.removeItem(at:f.root)}
        // A Squash editor normally has staged changes and must not offer Ignore.
        // Explicitly discard them so this actual failure meets the source gate.
        _=try await f.repository.run(["reset","--hard","HEAD"])
        let calls=try await hook(f),failure=try await fail(f.repository,message:"Rejected combination",squash:true)
        let saved=try await f.repository.rebaseState();XCTAssertNotNil(saved.squashMessage)
        let result=try await f.repository.ignoreRebaseCleanCommitFailure(failure,expected:saved,expectedHead:failure.head,editorExecutable:editor)
        XCTAssertFalse(result.state.active);XCTAssertEqual(attempts(calls),1)
        let actual=try await f.repository.rebaseCommit("HEAD");XCTAssertEqual(actual.hash,f.head.hash)
        let other=try await fixture();defer {try? FileManager.default.removeItem(at:other.root)}
        _=try await hook(other);_=try await fail(other.repository,message:"Kept until Abort")
        let aborted=try await other.repository.abortRebase();XCTAssertFalse(aborted.state.active)
        let restored=try await other.repository.rebaseCommit("HEAD");XCTAssertEqual(restored.hash,other.originalHead)
    }
    func testDirtyFailureRemainsOrdinaryGitFailureAndNoRecoveryReceiptIsSaved()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let calls=try await hook(f)
        try Data("dirty external change\n".utf8).write(to:f.root.appendingPathComponent("first.txt"))
        do {_=try await f.repository.continueRebase(editMessage:"Dirty attempt");XCTFail("Hook accepted")}catch let failure as GitFailure {XCTAssertTrue(failure.message.contains("Owned message commit refused"))}
        let state=try await f.repository.rebaseState();XCTAssertNil(state.cleanCommitFailure);XCTAssertEqual(attempts(calls),1)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent("first.txt")),Data("dirty external change\n".utf8))
    }
    func testStaleHeadSessionAndPrecancelledIgnoreCannotPublish()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let calls=try await hook(f),failure=try await fail(f.repository,message:"Draft")
        let state=try await f.repository.rebaseState(),token=OperationCancellation();token.cancel()
        do {_=try await f.repository.ignoreRebaseCleanCommitFailure(failure,expected:state,expectedHead:failure.head,cancellation:token);XCTFail("Cancelled Ignore accepted")}catch OperationCancellationFailure.cancelled {}
        let unchanged=try await f.repository.rebaseState();XCTAssertEqual(unchanged.cleanCommitFailure,failure)
        _=try await f.repository.run(["-c","core.hooksPath=/dev/null","commit","--amend","--no-edit"])
        // Even a commit with identical contents can differ through its committer;
        // explicitly move HEAD to a different ancestor for a deterministic guard.
        _=try await f.repository.run(["reset","--hard","HEAD~1"])
        do {_=try await f.repository.ignoreRebaseCleanCommitFailure(failure,expected:state,expectedHead:failure.head);XCTFail("Stale HEAD accepted")}catch RebaseFailure.changed {}
        do {_=try await f.repository.retryRebaseCleanCommitFailure(failure,expected:state,expectedHead:failure.head);XCTFail("Stale Retry accepted")}catch RebaseFailure.changed {}
        XCTAssertEqual(attempts(calls),1)
        _=try await f.repository.abortRebase()
        do {_=try await f.repository.ignoreRebaseCleanCommitFailure(failure,expected:state,expectedHead:failure.head);XCTFail("Retired session accepted")}catch RebaseFailure.changed {}
    }
    func testAcceptedIgnoreCancellationReopensAndRefusesDirtyResumeWithoutReamend()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let calls=try await hook(f),failure=try await fail(f.repository,message:"Ignore this text"),saved=try await f.repository.rebaseState()
        let wrapper=f.root.appendingPathComponent(".git/held-git")
        let script="""
        #!/bin/sh
        for argument in "$@"; do
            if [ "$argument" = '--continue' ]; then
                printf 'owned-ignore-continuation-held\\n'
                exec /bin/sleep 30
            fi
        done
        exec '\(f.repository.executable.path.replacingOccurrences(of:"'",with:"'\\''"))' "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let held=GitRepository(root:f.root,executable:wrapper,libgit2Configuration:.init(enabled:false)),token=OperationCancellation()
        do {
            _=try await held.ignoreRebaseCleanCommitFailure(failure,expected:saved,expectedHead:failure.head,cancellation:token,onOutput:{chunk in
                if String(decoding:chunk.data,as:UTF8.self).contains("owned-ignore-continuation-held") {token.cancel()}
            })
            XCTFail("Held continuation completed")
        }catch let cancelled as GitCommandCancellationFailure {
            XCTAssertTrue(token.isCancelled);XCTAssertEqual(cancelled.result.exitCode,130);XCTAssertTrue(cancelled.outputWasDelivered)
            XCTAssertTrue(String(decoding:cancelled.result.stdout,as:UTF8.self).contains("owned-ignore-continuation-held"))
        }
        let reopened=GitRepository(root:f.root,executable:f.repository.executable,libgit2Configuration:.init(enabled:false))
        let accepted=try await reopened.rebaseState();XCTAssertTrue(accepted.hasIgnoredCleanCommitFailure);XCTAssertNil(accepted.cleanCommitFailure);XCTAssertFalse(accepted.canSplit)
        try Data("new staged change\n".utf8).write(to:f.root.appendingPathComponent("first.txt"));try await reopened.stage(["first.txt"])
        do {_=try await reopened.continueRebase(editMessage:"Must not amend");XCTFail("Dirty accepted Ignore resumed")}catch RebaseFailure.changed {}
        let still=try await reopened.rebaseCommit("HEAD");XCTAssertEqual(still.hash,failure.head);XCTAssertEqual(attempts(calls),1)
        _=try await reopened.run(["reset","--hard","HEAD"])
        let done=try await reopened.continueRebase(editMessage:"Must still not amend",editorExecutable:editor)
        XCTAssertFalse(done.state.active);XCTAssertEqual(attempts(calls),1)
    }
    func testExternalStoppedEditArmsFutureEmptyWarningBeforeFailedAmendAndIgnore()async throws {
        let source=RebaseEmptyMessageTests(),f=try await source.fixture(message:"\nFuture raw empty body\n")
        defer {try? FileManager.default.removeItem(at:f.root)}
        let sequence=f.root.appendingPathComponent(".git/external-sequence")
        try Data("#!/bin/sh\n/usr/bin/sed '1s/^pick /edit /' \"$1\" > \"$1.tmp\" && /bin/mv \"$1.tmp\" \"$1\"\n".utf8).write(to:sequence)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:sequence.path)
        let externalEditor="'"+sequence.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        _=try await f.repository.run(["rebase","-i","upstream"],environmentOverrides:["GIT_SEQUENCE_EDITOR":externalEditor,"GIT_EDITOR":"/usr/bin/true"])
        let stopped=try await f.repository.rebaseState(),head=try await f.repository.rebaseCommit("HEAD")
        XCTAssertTrue(stopped.isEditPause)
        let owned=Fixture(root:f.root,repository:f.repository,originalHead:f.originalHead,head:head,state:stopped)
        let calls=try await hook(owned),failure=try await fail(f.repository,message:"External rejected amend")
        let saved=try await f.repository.rebaseState()
        let next=try await f.repository.ignoreRebaseCleanCommitFailure(failure,expected:saved,expectedHead:failure.head,editorExecutable:editor)
        XCTAssertEqual(next.state.emptyMessageWarning?.commit,f.empty.hash);XCTAssertEqual(attempts(calls),1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("empty.txt").path))
        let aborted=try await f.repository.abortRebase();XCTAssertFalse(aborted.state.active)
    }
    func testInterruptedAcceptedIgnoreJournalFinishesExactMessageBookkeeping()async throws {
        let f=try await fixture(nextSquash:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let calls=try await hook(f),failure=try await fail(f.repository,message:"Journal requested first\n\nOne body"),saved=try await f.repository.rebaseState()
        let record=f.root.appendingPathComponent(".git/rebase-merge/turtlegit-clean-commit-failure.json")
        let beforeBytes=try Data(contentsOf:record)
        let wrapper=f.root.appendingPathComponent(".git/journal-held-git")
        let script="""
        #!/bin/sh
        for argument in "$@"; do
            if [ "$argument" = '--continue' ]; then
                printf 'owned-journal-held\\n'
                exec /bin/sleep 30
            fi
        done
        exec '\(f.repository.executable.path.replacingOccurrences(of:"'",with:"'\\''"))' "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let held=GitRepository(root:f.root,executable:wrapper,libgit2Configuration:.init(enabled:false)),token=OperationCancellation()
        do {_=try await held.ignoreRebaseCleanCommitFailure(failure,expected:saved,expectedHead:failure.head,cancellation:token,onOutput:{chunk in
            if String(decoding:chunk.data,as:UTF8.self).contains("owned-journal-held"){token.cancel()}
        });XCTFail("Held replay completed")}catch let cancelled as GitCommandCancellationFailure {
            XCTAssertTrue(token.isCancelled);XCTAssertEqual(cancelled.result.exitCode,130);XCTAssertTrue(cancelled.outputWasDelivered)
            XCTAssertTrue(String(decoding:cancelled.result.stdout,as:UTF8.self).contains("owned-journal-held"))
        }
        let afterBytes=try Data(contentsOf:record)
        let beforeRecord=try XCTUnwrap(JSONSerialization.jsonObject(with:beforeBytes) as? [String:Any]),afterRecord=try XCTUnwrap(JSONSerialization.jsonObject(with:afterBytes) as? [String:Any])
        var before=try XCTUnwrap(beforeRecord["files"] as? [String:Any]),after=try XCTUnwrap(afterRecord["files"] as? [String:Any])
        before["turtlegit-clean-commit-failure.json"]=["bytes":beforeBytes.base64EncodedString()]
        after["turtlegit-clean-commit-failure.json"]=["bytes":afterBytes.base64EncodedString()]
        let directory=record.deletingLastPathComponent()
        // Use the actual two receipts as an interrupted transaction, with the
        // editor accumulator still old while other completion files are new.
        let editorName="turtlegit-message-editor.json"
        let old=try XCTUnwrap(before[editorName] as? [String:Any]),oldBase64=try XCTUnwrap(old["bytes"] as? String),oldBytes=try XCTUnwrap(Data(base64Encoded:oldBase64))
        try oldBytes.write(to:directory.appendingPathComponent(editorName),options:.atomic)
        try beforeBytes.write(to:record,options:.atomic)
        let journal=directory.appendingPathComponent("turtlegit-action-edit.json")
        try JSONSerialization.data(withJSONObject:["version":3,"before":before,"after":after],options:[.sortedKeys]).write(to:journal,options:.atomic)
        let reopened=GitRepository(root:f.root,executable:f.repository.executable,libgit2Configuration:.init(enabled:false))
        let recovered=try await reopened.rebaseState();XCTAssertTrue(recovered.hasIgnoredCleanCommitFailure);XCTAssertNil(recovered.cleanCommitFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath:journal.path));XCTAssertEqual(try Data(contentsOf:record),afterBytes)
        let result=try await reopened.continueRebase(editorExecutable:editor)
        XCTAssertTrue(result.state.squashMessage?.message.contains("Journal requested first") == true);XCTAssertEqual(attempts(calls),1)
        _=try await reopened.abortRebase()
    }
    func testOlderStateJSONDoesNotRequireSeparateRecoveryJournalFields()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let encoded=try JSONEncoder().encode(f.state)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertNil(object["cleanCommitFailure"]);XCTAssertNil(object["hasIgnoredCleanCommitFailure"])
        let decoded=try JSONDecoder().decode(RebaseState.self,from:encoded)
        XCTAssertEqual(decoded.stoppedEntryID,f.state.stoppedEntryID);XCTAssertNil(decoded.cleanCommitFailure);XCTAssertFalse(decoded.hasIgnoredCleanCommitFailure)
    }
}
