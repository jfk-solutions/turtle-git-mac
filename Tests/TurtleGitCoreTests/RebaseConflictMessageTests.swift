import XCTest
@testable import TurtleGitCore

final class RebaseConflictMessageTests:XCTestCase {
    var editor:URL {RebaseTests().editor}
    struct Fixture {
        let root:URL,repository:GitRepository,path:String,source:LogEntry,originalHead:String,destination:String
    }
    func fixture(action:RebaseAction = .pick,nextSquash:Bool=false,extraSquash:Bool=false,cherry:Bool=false,rawMessage:Data?=nil,encoding:String?=nil)async throws->Fixture {
        let(root,original,path)=try await RebaseTests().fixture(conflict:true)
        var accepted=false;defer {if !accepted {try? FileManager.default.removeItem(at:root)}}
        let repo=GitRepository(root:root,executable:original.executable,libgit2Configuration:.init(enabled:false))
        _=try await repo.run(["config","core.hooksPath","/dev/null"])
        if extraSquash {
            try Data("third payload\n".utf8).write(to:root.appendingPathComponent("third.txt"))
            _=try await repo.run(["add","third.txt"]);_=try await repo.run(["commit","-m","third source member"])
        }
        var plan=try await repo.rebasePlan(RebaseTests().options())
        if let rawMessage {
            let commit=plan.entries[0].commit
            let tree=String(decoding:try await repo.run(["rev-parse",commit.hash+"^{tree}"]).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
            if let encoding {_=try await repo.run(["config","i18n.commitEncoding",encoding])}
            let file=root.appendingPathComponent(".git/raw-source-message");try rawMessage.write(to:file)
            let hash=String(decoding:try await repo.run(["commit-tree",tree,"-p",commit.parents[0],"-F",file.path],environmentOverrides:["GIT_AUTHOR_NAME":"Raw Source Author","GIT_AUTHOR_EMAIL":"raw-source@example.invalid","GIT_AUTHOR_DATE":"2026-10-10T10:00:00+0200"]).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
            _=try await repo.run(["reset","--hard",hash]);plan=try await repo.rebasePlan(RebaseTests().options())
        }
        let source=plan.entries[0].commit
        if cherry {
            _=try await repo.run(["switch","upstream"])
            plan=try await repo.cherryPickPlan(revisions:[source.hash])
        }
        plan.entries[0].action=action
        for index in plan.entries.indices where index>0 {plan.entries[index].action=nextSquash ? .squash:.skip}
        let originalHead=plan.branchHash
        var stopped=try await repo.startRebase(plan,editorExecutable:editor)
        if let warning=stopped.state.emptyMessageWarning {stopped=try await repo.acknowledgeRebaseEmptyMessage(warning,expected:stopped.state,expectedHead:warning.head)}
        XCTAssertNotEqual(stopped.exitCode,0);XCTAssertFalse(stopped.state.conflicts.isEmpty)
        try Data("resolved conflict\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path])
        let destination=try await repo.rebaseCommit("HEAD").hash
        accepted=true;return .init(root:root,repository:repo,path:path,source:source,originalHead:originalHead,destination:destination)
    }
    func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    func hooks(_ f:Fixture,mode:String="ok")async throws->URL {
        let folder=f.root.appendingPathComponent(".git/message-hooks",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data(mode.utf8).write(to:folder.appendingPathComponent("mode"))
        let script="""
        #!/bin/sh
        folder=\(quote(folder.path))
        n=0; [ ! -f "$folder/count" ] || read n < "$folder/count"
        n=$((n + 1)); printf '%s\\n' "$n" > "$folder/count"
        /bin/cp "$1" "$folder/message-$n"
        printf '%s\\n' "$2" "$3" > "$folder/source-$n"
        printf 'owned-conflict-hook-entered\\n'
        read mode < "$folder/mode"
        if [ "$mode" = initial ] || { [ "$mode" = amend ] && [ "$n" -ge 2 ]; }; then
            printf 'owned-conflict-message-refusal\\n' >&2
            exit 73
        fi
        """
        let hook=folder.appendingPathComponent("prepare-commit-msg")
        try Data(script.utf8).write(to:hook);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        _=try await f.repository.run(["config","core.hooksPath",folder.path]);return folder
    }
    func count(_ folder:URL)->Int {Int((try? String(contentsOf:folder.appendingPathComponent("count"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) ?? "0") ?? 0}
    func begin(_ f:Fixture,raw:String)async throws->RebaseExecution {
        let state=try await f.repository.rebaseState(),rows=try await f.repository.status()
        return try await f.repository.beginRebaseConflictMessage(rawMessage:raw,paths:[f.path],expected:state,expectedHead:f.destination,indexPolicy:.init(paths:rows.map(\.path)))
    }
    func complete(_ f:Fixture,_ state:RebaseState,raw:String,prepared:String?)async throws->RebaseExecution {
        try await f.repository.completeRebaseConflictMessage(amendMessage:prepared,expected:state,expectedHead:try XCTUnwrap(state.conflictMessage).head,editorExecutable:editor,rawMessage:raw)
    }
    func testHooksObserveOriginalReuseThenOnlyChangedMessageAmend()async throws {
        for changed in [false,true] {
            let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
            let observed=try await hooks(f),draft=changed ? "Edited source subject\n\nExact edited body 🐢":f.source.message
            let first=try await begin(f,raw:draft),phase=try XCTUnwrap(first.state.conflictMessage),head=try await f.repository.rebaseCommit("HEAD")
            XCTAssertEqual(count(observed),1);XCTAssertEqual(head.message,f.source.message);XCTAssertEqual(head.author,f.source.author);XCTAssertEqual(head.date,f.source.date)
            let hookMessage=try Data(contentsOf:observed.appendingPathComponent("message-1")),source=try String(contentsOf:observed.appendingPathComponent("source-1"),encoding:.utf8)
            XCTAssertEqual(hookMessage,Data(f.source.message.utf8));XCTAssertEqual(source,"commit\n"+f.source.hash+"\n")
            XCTAssertEqual(phase.needsAmend,changed);XCTAssertEqual(phase.beforeHead,f.destination);XCTAssertEqual(first.witnessedHead,head.hash)
            let done=try await complete(f,first.state,raw:draft,prepared:changed ? draft:nil)
            XCTAssertFalse(done.state.active);XCTAssertEqual(count(observed),changed ? 2:1)
            let actual=try await f.repository.rebaseCommit("HEAD")
            XCTAssertEqual(actual.parents,[f.destination]);XCTAssertEqual(actual.author,f.source.author);XCTAssertEqual(actual.date,f.source.date)
            XCTAssertEqual(actual.message.trimmingCharacters(in:.newlines),draft.trimmingCharacters(in:.newlines))
        }
    }
    func testChangedEmptyDraftIsRejectedAfterOriginalCommitAndCanBeCorrectedAfterReopen()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let observed=try await hooks(f),first=try await begin(f,raw:f.source.message)
        let initial=try await f.repository.rebaseCommit("HEAD")
        do {_=try await complete(f,first.state,raw:" \n\t",prepared:nil);XCTFail("Changed empty draft accepted")}catch RebaseFailure.message {}
        let reopened=GitRepository(root:f.root,executable:f.repository.executable,libgit2Configuration:.init(enabled:false)),pending=try await reopened.rebaseState()
        XCTAssertEqual(pending.conflictMessage?.rawMessage," \n\t");XCTAssertEqual(count(observed),1)
        let kept=try await reopened.rebaseCommit("HEAD");XCTAssertEqual(kept.hash,initial.hash);XCTAssertEqual(kept.message,f.source.message)
        let done=try await reopened.completeRebaseConflictMessage(amendMessage:"Corrected after reopen",expected:pending,expectedHead:initial.hash,editorExecutable:editor,rawMessage:"Corrected after reopen")
        XCTAssertFalse(done.state.active);XCTAssertEqual(count(observed),2)
    }
    func testUnchangedEmptyOriginalAndLegacyEncodedMessageAreReusedWithoutAmend()async throws {
        for(bytes,encoding)in [(Data(),Optional<String>.none),(Data("\nBody with empty first line\n".utf8),nil),(Data([0x43,0x61,0x66,0xe9,0x0a,0x0a,0x42,0x6f,0x64,0x79,0x0a]),Optional("windows-1252"))] {
            let f=try await fixture(rawMessage:bytes,encoding:encoding);defer {try? FileManager.default.removeItem(at:f.root)}
            let observed=try await hooks(f),first=try await begin(f,raw:f.source.message)
            let phase=try XCTUnwrap(first.state.conflictMessage)
            XCTAssertFalse(phase.needsAmend)
            let original=try await f.repository.run(["cat-file","commit",f.source.hash]).stdout
            let originalSeparator=try XCTUnwrap(original.range(of:Data([10,10])))
            XCTAssertEqual(Data(original[originalSeparator.upperBound...]),bytes)
            XCTAssertEqual(phase.originalMessage,try CommitMessageEncoding.decode(bytes,name:encoding ?? ""))
            // Git's source-equivalent -C itself skips leading blank lines before
            // its prepare-commit-msg hook (builtin/commit.c); retain the exact
            // original receipt while checking that distinct published result.
            let reused=bytes.first==10 ? Data(bytes.dropFirst()):bytes
            XCTAssertEqual(try Data(contentsOf:observed.appendingPathComponent("message-1")),reused)
            let done=try await complete(f,first.state,raw:f.source.message,prepared:nil)
            if bytes.isEmpty || bytes.first==10 {XCTAssertTrue(done.state.active);XCTAssertTrue(done.state.isEditPause,"Original empty subject retains its mandatory applied review")}
            else {XCTAssertFalse(done.state.active)}
            XCTAssertEqual(count(observed),1)
            let object=try await f.repository.run(["cat-file","commit","HEAD"]).stdout
            let separator=try XCTUnwrap(object.range(of:Data([10,10])))
            XCTAssertEqual(Data(object[separator.upperBound...]),reused)
            if done.state.active {_=try await f.repository.abortRebase()}
        }
    }
    func testInitialFailureIsOrdinaryAndRetryDoesNotPublishASecondPhase()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let observed=try await hooks(f,mode:"initial")
        do {_=try await begin(f,raw:"Edited after resolution");XCTFail("Initial hook accepted")}catch let failure as GitFailure {XCTAssertTrue(failure.message.contains("owned-conflict-message-refusal"))}
        let state=try await f.repository.rebaseState(),head=try await f.repository.rebaseCommit("HEAD")
        XCTAssertNil(state.conflictMessage);XCTAssertNil(state.cleanCommitFailure);XCTAssertEqual(head.hash,f.destination);XCTAssertEqual(count(observed),1)
        try Data("ok".utf8).write(to:observed.appendingPathComponent("mode"))
        let first=try await begin(f,raw:"Edited after resolution")
        XCTAssertNotNil(first.state.conflictMessage);XCTAssertEqual(count(observed),2)
        _=try await f.repository.abortRebase()
    }
    func testSecondaryRetryNeverRepeatsInitialCommitAndIgnoreRespectsPickEditAndCherryPick()async throws {
        for(action,cherry)in [(RebaseAction.pick,false),(.edit,false),(.pick,true)] {
            let f=try await fixture(action:action,cherry:cherry);defer {try? FileManager.default.removeItem(at:f.root)}
            let observed=try await hooks(f,mode:"amend"),first=try await begin(f,raw:"Rejected new subject"),firstHead=try await f.repository.rebaseCommit("HEAD")
            let failure:RebaseCleanCommitFailure
            do {_=try await complete(f,first.state,raw:"Rejected new subject",prepared:"Rejected new subject");XCTFail("Second hook accepted");throw RebaseFailure.plan}catch let actual as RebaseCleanCommitFailure {failure=actual}
            let failed=try await f.repository.rebaseState();XCTAssertNotNil(failed.conflictMessage);XCTAssertEqual(count(observed),2)
            let retry=try await f.repository.retryRebaseCleanCommitFailure(failure,expected:failed,expectedHead:failure.head)
            XCTAssertNil(retry.cleanCommitFailure);XCTAssertNotNil(retry.conflictMessage);XCTAssertEqual(count(observed),2)
            let second:RebaseCleanCommitFailure
            do {_=try await complete(f,retry,raw:"Rejected new subject",prepared:"Rejected new subject");XCTFail("Retry accepted");throw RebaseFailure.plan}catch let actual as RebaseCleanCommitFailure {second=actual}
            let saved=try await f.repository.rebaseState()
            let result=try await f.repository.ignoreRebaseCleanCommitFailure(second,expected:saved,expectedHead:second.head,editorExecutable:editor)
            XCTAssertEqual(count(observed),3)
            let actual=try await f.repository.rebaseCommit("HEAD");XCTAssertEqual(actual.hash,firstHead.hash);XCTAssertEqual(actual.message,f.source.message)
            if action == .edit {XCTAssertTrue(result.state.isEditPause);XCTAssertEqual(result.state.split?.conflictRecovery,true);XCTAssertNil(result.state.conflictMessage)}else{XCTAssertFalse(result.state.active)}
            if result.state.active {_=try await f.repository.abortRebase()}
        }
    }
    func testCommentStrippedEmptyPreparedTextStillAttemptsSecondGitCommand()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let observed=try await hooks(f),raw="# Entire edited draft is stripped\n",first=try await begin(f,raw:raw)
        let failure:RebaseCleanCommitFailure
        do {_=try await complete(f,first.state,raw:raw,prepared:"");XCTFail("Empty prepared message committed");throw RebaseFailure.plan}catch let actual as RebaseCleanCommitFailure {failure=actual}
        let pending=try await f.repository.rebaseState()
        XCTAssertEqual(count(observed),2);XCTAssertEqual(failure.message,"");XCTAssertNotNil(pending.conflictMessage)
        let saved=try await f.repository.rebaseState(),done=try await f.repository.ignoreRebaseCleanCommitFailure(failure,expected:saved,expectedHead:failure.head)
        XCTAssertFalse(done.state.active);XCTAssertEqual(count(observed),2)
    }
    func testIgnoreBeforeNextSquashPreservesRequestedAccumulatorOnceAndActualFirstAuthor()async throws {
        let f=try await fixture(nextSquash:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let observed=try await hooks(f,mode:"amend"),draft="Requested conflict subject\n\nOne requested conflict body 🐢",first=try await begin(f,raw:draft)
        let failure:RebaseCleanCommitFailure
        do {_=try await complete(f,first.state,raw:draft,prepared:draft);XCTFail("Second hook accepted");throw RebaseFailure.plan}catch let actual as RebaseCleanCommitFailure {failure=actual}
        let saved=try await f.repository.rebaseState(),next=try await f.repository.ignoreRebaseCleanCommitFailure(failure,expected:saved,expectedHead:failure.head,editorExecutable:editor)
        let thirdSource=(try? String(contentsOf:observed.appendingPathComponent("source-3"),encoding:.utf8)) ?? "<absent>"
        let combined=try XCTUnwrap(next.state.squashMessage?.message,"exit=\(next.exitCode),step=\(next.state.currentStep),action=\(String(describing:next.state.stoppedAction)),conflicts=\(next.state.conflicts),split=\(String(describing:next.state.split)),hookCount=\(count(observed)),thirdSource=\(thirdSource),output=\(next.output)")
        XCTAssertTrue(combined.hasPrefix("Requested conflict subject"));XCTAssertEqual(combined.components(separatedBy:"One requested conflict body 🐢").count-1,1);XCTAssertTrue(combined.contains("second"));XCTAssertEqual(count(observed),2)
        _=try await f.repository.run(["config","core.hooksPath","/dev/null"])
        let done=try await f.repository.continueRebase(squashMessage:combined,editorExecutable:editor)
        XCTAssertFalse(done.state.active)
        let actual=try await f.repository.rebaseCommit("HEAD");XCTAssertEqual(actual.author,f.source.author);XCTAssertEqual(actual.date,f.source.date)
        XCTAssertEqual(actual.message.components(separatedBy:"One requested conflict body 🐢").count-1,1)
    }
    func testContiguousSquashTransportForwardsOriginalPostHookAndNestedRepositoryHooks()async throws {
        let f=try await fixture(nextSquash:true,extraSquash:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let observed=try await hooks(f,mode:"amend")
        let nestedRoot=f.root.appendingPathComponent(".git/nested-hook-repository",isDirectory:true)
        try FileManager.default.createDirectory(at:nestedRoot,withIntermediateDirectories:true)
        let nested=GitRepository(root:nestedRoot,executable:f.repository.executable,libgit2Configuration:.init(enabled:false))
        _=try await nested.run(["init"]);_=try await nested.run(["config","user.name","Nested Hook Author"]);_=try await nested.run(["config","user.email","nested@example.invalid"])
        let nestedHook=nestedRoot.appendingPathComponent(".git/hooks/prepare-commit-msg")
        _=try await nested.run(["config","core.hooksPath",nestedHook.deletingLastPathComponent().path])
        let nestedLog=observed.appendingPathComponent("nested-log"),postLog=observed.appendingPathComponent("post-log")
        let nestedScript="#!/bin/sh\nprintf '%s\\n' \"$0\" >> "+quote(nestedLog.path)+"\n"
        try Data(nestedScript.utf8).write(to:nestedHook);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:nestedHook.path)
        let post=observed.appendingPathComponent("post-commit")
        let postScript="""
        #!/bin/sh
        printf '%s\\n' "$0" >> \(quote(postLog.path))
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
        \(quote(f.repository.executable.path)) -C \(quote(nestedRoot.path)) commit --allow-empty -m nested-hook-commit >/dev/null || exit $?
        """
        try Data(postScript.utf8).write(to:post);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:post.path)
        let draft="Reviewed conflict before contiguous group",first=try await begin(f,raw:draft)
        let failure:RebaseCleanCommitFailure
        do {_=try await complete(f,first.state,raw:draft,prepared:draft);XCTFail("Secondary message hook accepted");throw RebaseFailure.plan}catch let actual as RebaseCleanCommitFailure {failure=actual}
        let saved=try await f.repository.rebaseState()
        let next=try await f.repository.ignoreRebaseCleanCommitFailure(failure,expected:saved,expectedHead:failure.head,editorExecutable:editor)
        let combined=try XCTUnwrap(next.state.squashMessage?.message,next.output)
        XCTAssertTrue(combined.contains("second"));XCTAssertTrue(combined.contains("third source member"));XCTAssertTrue(combined.hasPrefix(draft))
        XCTAssertEqual(count(observed),2,"Only the explicit original commit and rejected explicit amendment run preparation hooks before approval")
        let forwarded=try String(contentsOf:postLog,encoding:.utf8).split(separator:"\n").map(String.init)
        let nestedCalls=try String(contentsOf:nestedLog,encoding:.utf8).split(separator:"\n").map(String.init)
        XCTAssertGreaterThanOrEqual(forwarded.count,2,"The intermediate contiguous squash must forward the real post-commit hook")
        XCTAssertTrue(forwarded.allSatisfy{$0==post.path},"actual forwarded paths=\(forwarded), configured original=\(post.path), root=\(f.root.path)");XCTAssertEqual(nestedCalls.count,forwarded.count)
        XCTAssertTrue(nestedCalls.allSatisfy{$0==nestedHook.path},"Nested Git must resolve its own original hook instead of inheriting the temporary overlay")
        // Final user approval is a real message commit, not preparation transport.
        do {_=try await f.repository.continueRebase(squashMessage:combined,editorExecutable:editor);XCTFail("Manual approval bypassed the rejecting original hook")}
        catch let failure as GitFailure {XCTAssertTrue(failure.message.contains("owned-conflict-message-refusal"))}
        catch let failure as RebaseCleanCommitFailure {XCTAssertTrue(failure.diagnostic.contains("owned-conflict-message-refusal"))}
        XCTAssertEqual(count(observed),3)
        _=try await f.repository.abortRebase()
    }
    func testCancellationAfterFirstCommitReopensPendingPhaseAndRejectsChangedIndexOrHead()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let observed=try await hooks(f),state=try await f.repository.rebaseState(),token=OperationCancellation()
        do {_=try await f.repository.beginRebaseConflictMessage(rawMessage:"Cancelled retained draft",paths:[f.path],expected:state,expectedHead:f.destination,cancellation:token,onOutput:{chunk in
            if String(decoding:chunk.data,as:UTF8.self).contains("owned-conflict-hook-entered") {token.cancel()}
        },indexPolicy:.init(paths:[f.path]));XCTFail("Late cancelled first phase completed")}catch OperationCancellationFailure.cancelled {}
        XCTAssertTrue(token.isCancelled);XCTAssertEqual(count(observed),1)
        let reopened=GitRepository(root:f.root,executable:f.repository.executable,libgit2Configuration:.init(enabled:false)),pending=try await reopened.rebaseState(),phase=try XCTUnwrap(pending.conflictMessage)
        XCTAssertEqual(phase.phase,.pending);XCTAssertEqual(phase.rawMessage,"Cancelled retained draft")
        try Data("unrelated staged content\n".utf8).write(to:f.root.appendingPathComponent("external.txt"));try await reopened.stage(["external.txt"])
        do {_=try await reopened.completeRebaseConflictMessage(amendMessage:"Must not run",expected:pending,expectedHead:phase.head,rawMessage:"Must not run");XCTFail("Changed index accepted")}catch RebaseFailure.changed {}
        XCTAssertEqual(count(observed),1)
        _=try await reopened.run(["reset","--hard",phase.head])
        let current=try await reopened.rebaseState()
        _=try await reopened.run(["reset","--hard",phase.beforeHead])
        let uncertain=try await reopened.rebaseState();XCTAssertEqual(uncertain.conflictMessage?.phase,.uncertain)
        do {_=try await reopened.completeRebaseConflictMessage(amendMessage:nil,expected:uncertain,expectedHead:phase.beforeHead);XCTFail("Changed HEAD accepted")}catch RebaseFailure.conflictMessageUncertain {}
        do {_=try await reopened.beginRebaseConflictMessage(rawMessage:"Must not repeat",paths:[f.path],expected:current,expectedHead:phase.head);XCTFail("Initial phase repeated")}catch RebaseFailure.changed {}
        XCTAssertEqual(count(observed),1);_=try await reopened.abortRebase()
    }
}
