// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class CommitNoteCancellationTests:XCTestCase {
    struct Failure:Error {let message:String}
    struct Witness:Equatable {let head:Data,index:Data,working:Data,config:Data}
    var git:URL {URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")}
    func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    func fixture()async throws->(URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitNoteCancellation-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let repo=GitRepository(root:root,executable:git,askpass:nil)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Private note QA"),("user.email","note@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("tracked"));try await repo.stage(["tracked"]);_=try await repo.commit(message:"Private notes baseline")
        try Data("unstaged working bytes\n".utf8).write(to:root.appendingPathComponent("tracked"))
        return(root,repo)
    }
    func witness(_ repo:GitRepository)async throws->Witness {
        .init(head:try await repo.run(["rev-parse","HEAD"]).stdout,index:try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),working:try Data(contentsOf:repo.root.appendingPathComponent("tracked")),config:try Data(contentsOf:repo.root.appendingPathComponent(".git/config")))
    }
    func wrapper(_ root:URL,name:String,body:String)throws->URL {
        let file=root.appendingPathComponent(".git/"+name)
        let script="#!/bin/sh\nif [ \"${4-}\" = hash-object ]; then printf '%s' \"${7-}\" > \"$0.note-file\"; fi\n"+body+"\nexec "+quote(git.path)+" \"$@\"\n"
        try Data(script.utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path);return file
    }
    var block:String {"""
      /bin/sleep 30 &
      task_note_child=$!
      trap 'kill "$task_note_child" 2>/dev/null; wait "$task_note_child" 2>/dev/null; exit 143' TERM INT
      printf '%s %s\\n' "$$" "$task_note_child" > "$0.started.tmp"
      /bin/mv "$0.started.tmp" "$0.started"
      wait "$task_note_child"
    """}
    func started(_ wrapper:URL)async throws->[Int32] {
        let marker=URL(fileURLWithPath:wrapper.path+".started")
        for _ in 0..<500 {
            if let value=try? String(contentsOf:marker),!value.isEmpty {let ids=value.split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)};if ids.count==2{return ids}}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        throw Failure(message:"Owned note child did not start: "+wrapper.lastPathComponent)
    }
    func drained(_ pids:[Int32])async {
        for _ in 0..<300 {if pids.allSatisfy({kill($0,0) != 0}){return};try? await Task.sleep(nanoseconds:10_000_000)}
        let remaining=pids.filter{kill($0,0)==0}
        if let group=pids.first {remaining.filter{getpgid($0)==group}.forEach{_ = kill($0,SIGKILL)}}
        XCTFail("Owned note process did not drain: \(remaining)")
    }
    func assertTemporaryInputRemoved(_ wrapper:URL)throws {
        let file=try String(contentsOf:URL(fileURLWithPath:wrapper.path+".note-file"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:URL(fileURLWithPath:file).deletingLastPathComponent().path),"Note temporary directory survived cancellation")
    }
    func testPreCancelledSaveDoesNotLaunchOrMutate()async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let note=try await repo.editableCommitNote(revision:"HEAD"),before=try await witness(repo)
        let helper=try wrapper(root,name:"must-not-run",body:"printf started > \"$0.launched\"")
        let stopped=OperationCancellation();stopped.cancel()
        do {_=try await GitRepository(root:root,executable:helper,askpass:nil).saveCommitNote(note,text:"Cancelled before start",cancellation:stopped);XCTFail("Pre-cancelled note save completed")}
        catch {XCTAssertTrue(error is OperationCancellationFailure)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:helper.path+".launched"))
        let after=try await witness(repo),reread=try await repo.editableCommitNote(revision:note.revision)
        XCTAssertEqual(after,before);XCTAssertEqual(reread.text,"")
    }
    func testOwnedHashAndPreWriteNotesCancellationPreservesPublishedNoteAndCanRetry()async throws {
        for phase in ["hash","notes"] {
            let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            var note=try await repo.editableCommitNote(revision:"HEAD");_=try await repo.saveCommitNote(note,text:"Original published note");note=try await repo.editableCommitNote(revision:note.revision)
            let before=try await witness(repo),refBefore=try await repo.run(["rev-parse",note.notesRef]).stdout
            let match=phase=="hash" ? "[ \"${4-}\" = hash-object ]":"[ \"${4-}\" = notes ] && [ \"${6-}\" = add ]"
            let helper=try wrapper(root,name:"before-"+phase,body:"if "+match+"; then\n"+block+"\nfi")
            let slow=GitRepository(root:root,executable:helper,askpass:nil),token=OperationCancellation(),captured=note
            let task=Task{try await slow.saveCommitNote(captured,text:"Never published",cancellation:token)}
            var ids:[Int32]=[]
            do {
                ids=try await started(helper);XCTAssertTrue(ids.allSatisfy{kill($0,0)==0});token.cancel()
                do {_=try await task.value;XCTFail("Cancelled live note write completed")}
                catch {XCTAssertTrue(error is OperationCancellationFailure || error is GitCommandCancellationFailure,"Unexpected \(phase) cancellation classification: \(error)")}
                await drained(ids)
            } catch {token.cancel();_=await task.result;await drained(ids);throw error}
            let after=try await witness(repo),refAfter=try await repo.run(["rev-parse",note.notesRef]).stdout,reread=try await repo.editableCommitNote(revision:note.revision)
            XCTAssertEqual(after,before);XCTAssertEqual(refAfter,refBefore);XCTAssertEqual(reread.text,"Original published note");try assertTemporaryInputRemoved(helper)
            _=try await repo.saveCommitNote(note,text:"Independent retry");let retried=try await repo.editableCommitNote(revision:note.revision);XCTAssertEqual(retried.text,"Independent retry")
        }
    }
    func testCancellationAfterNotesRefMutationReportsStoredContentAndKeepsCapturedTarget()async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=try await repo.run(["config","core.notesRef","refs/notes/captured-review"])
        let note=try await repo.editableCommitNote(revision:"HEAD")
        _=try await repo.run(["config","core.notesRef","refs/notes/later-default"])
        let before=try await witness(repo),text="  exact saved note\n# literal\r\n雪🐢  "
        let helper=try wrapper(root,name:"after-notes-write",body:"if [ \"${4-}\" = notes ] && [ \"${6-}\" = add ]; then\n"+quote(git.path)+" \"$@\" || exit $?\n"+block+"\nexit 0\nfi")
        let slow=GitRepository(root:root,executable:helper,askpass:nil),token=OperationCancellation()
        let task=Task{try await slow.saveCommitNote(note,text:text,cancellation:token)};var ids:[Int32]=[]
        do {
            ids=try await started(helper);token.cancel()
            do {_=try await task.value;XCTFail("Cancelled post-mutation wait completed normally")}
            catch CommitNoteFailure.savedButRefreshFailed(let message) {XCTAssertTrue(message.lowercased().contains("cancel"))}
            catch {XCTFail("Completed note write misreported as unsaved: \(error)")}
            await drained(ids)
        } catch {token.cancel();_=await task.result;await drained(ids);throw error}
        let blob=try await repo.run(["notes","--ref="+note.notesRef,"list",note.revision]).text.trimmingCharacters(in:.newlines),bytes=try await repo.run(["cat-file","blob",blob]).stdout
        let other=try await repo.run(["show-ref","--verify","--quiet","refs/notes/later-default"],successfulExitCodes:0...1).exitCode,after=try await witness(repo)
        XCTAssertEqual(bytes,Data(text.utf8));XCTAssertEqual(other,1);XCTAssertEqual(after,before);try assertTemporaryInputRemoved(helper)
    }
    func testCancellationDuringDisplayRefreshReportsSavedNote()async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let note=try await repo.editableCommitNote(revision:"HEAD"),before=try await witness(repo)
        let helper=try wrapper(root,name:"display-after-write",body:"case \"$*\" in\n *--format=%N*)\n"+block+"\n ;;\nesac")
        let slow=GitRepository(root:root,executable:helper,askpass:nil),token=OperationCancellation()
        let task=Task{try await slow.saveCommitNote(note,text:"Stored before display cancellation",cancellation:token)};var ids:[Int32]=[]
        do {
            ids=try await started(helper);token.cancel()
            do {_=try await task.value;XCTFail("Cancelled display refresh completed normally")}
            catch CommitNoteFailure.savedButRefreshFailed(let message) {XCTAssertTrue(message.lowercased().contains("cancel"))}
            catch {XCTFail("Display cancellation hid completed write: \(error)")}
            await drained(ids)
        } catch {token.cancel();_=await task.result;await drained(ids);throw error}
        let saved=try await repo.editableCommitNote(revision:note.revision),after=try await witness(repo)
        XCTAssertEqual(saved.text,"Stored before display cancellation");XCTAssertEqual(after,before);try assertTemporaryInputRemoved(helper)
    }
    func testFailedMutationRecoveryDistinguishesUnchangedConflictingAndUnreadableState()async throws {
        for mode in ["unchanged","conflicting","unreadable"] {
            let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            var note=try await repo.editableCommitNote(revision:"HEAD");_=try await repo.saveCommitNote(note,text:"Existing note");note=try await repo.editableCommitNote(revision:note.revision)
            let before=try await witness(repo)
            let otherFile=root.appendingPathComponent(".git/other-note");try Data("Other published content".utf8).write(to:otherFile)
            let otherBlob=try await repo.run(["hash-object","-w",otherFile.path]).text.trimmingCharacters(in:.newlines)
            var body=""
            if mode=="unreadable" {body="if [ -f \"$0.changed\" ] && [ \"${4-}\" = rev-parse ]; then printf 'controlled recovery read failure\\n' >&2;exit 91;fi\n"}
            body += "if [ \"${4-}\" = notes ] && [ \"${6-}\" = add ]; then\n"
            if mode != "unchanged" {body += quote(git.path)+" \"$@\" || exit $?\n"}
            if mode=="conflicting" {body += quote(git.path)+" --literal-pathspecs -C "+quote(root.path)+" notes --ref="+quote(note.notesRef)+" add --force --reuse-message "+quote(otherBlob)+" "+quote(note.revision)+" || exit $?\n"}
            if mode=="unreadable" {body += "printf changed > \"$0.changed\"\n"}
            body += "printf 'controlled mutation receipt failure\\n' >&2;exit 37\nfi"
            let helper=try wrapper(root,name:"receipt-"+mode,body:body),wrapped=GitRepository(root:root,executable:helper,askpass:nil)
            do {_=try await wrapped.saveCommitNote(note,text:"Requested content");XCTFail("Failing mutation receipt succeeded")}
            catch let failure as GitFailure {XCTAssertEqual(mode,"unchanged");XCTAssertEqual(failure.code,37)}
            catch CommitNoteFailure.saveOutcomeUnknown(let detail) {XCTAssertNotEqual(mode,"unchanged");XCTAssertTrue(detail.contains("controlled"))}
            catch {XCTFail("Unexpected recovery classification: \(error)")}
            let saved=try await repo.editableCommitNote(revision:note.revision),after=try await witness(repo)
            XCTAssertEqual(saved.text,mode=="unchanged" ? "Existing note":mode=="conflicting" ? "Other published content":"Requested content");XCTAssertEqual(after,before);try assertTemporaryInputRemoved(helper)
        }
    }
    func testRecoveryProbeIsBoundedAndReapsItsOwnedChild()async throws {
        let(root,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let note=try await repo.editableCommitNote(revision:"HEAD"),before=try await witness(repo)
        let body="if [ -f \"$0.changed\" ] && [ \"${4-}\" = rev-parse ]; then\n"+block+"\nfi\nif [ \"${4-}\" = notes ] && [ \"${6-}\" = add ]; then\n"+quote(git.path)+" \"$@\" || exit $?\nprintf changed > \"$0.changed\"\nexit 37\nfi"
        let helper=try wrapper(root,name:"bounded-recovery",body:body),wrapped=GitRepository(root:root,executable:helper,askpass:nil),startedAt=Date()
        let task=Task{try await wrapped.saveCommitNote(note,text:"Stored before bounded recovery")};var ids:[Int32]=[]
        do {
            ids=try await started(helper)
            do {_=try await task.value;XCTFail("Timed-out recovery was reported as success")}
            catch CommitNoteFailure.saveOutcomeUnknown(_) { }
            catch {XCTFail("Uncertain timed-out recovery lost explicit inspection warning: \(error)")}
            await drained(ids);XCTAssertLessThan(Date().timeIntervalSince(startedAt),10,"Recovery waited for the private 30-second helper instead of its bounded token")
        } catch {_=await task.result;await drained(ids);throw error}
        let saved=try await repo.editableCommitNote(revision:note.revision),after=try await witness(repo)
        XCTAssertEqual(saved.text,"Stored before bounded recovery");XCTAssertEqual(after,before);try assertTemporaryInputRemoved(helper)
    }
}
