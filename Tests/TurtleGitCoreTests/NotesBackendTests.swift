// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class NotesBackendTests:XCTestCase {
    private struct Fixture {let root:URL,cli:GitRepository,head:String}
    private struct Witness:Equatable {let head:Data,index:Data,working:Data,config:Data}
    private var git:URL {URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")}
    private var runtime:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2")}
    private func repository(_ root:URL,enabled:Bool=true,helper:URL?=nil,executable:URL?=nil)->GitRepository {
        GitRepository(root:root,executable:executable ?? git,askpass:nil,libgit2Configuration:.init(enabled:enabled,mask:0,helperURL:helper))
    }
    private func initial()async throws->(URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitNotesBackend-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let cli=repository(root,enabled:false)
        _=try await cli.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Config Notes Author"),("user.email","config-notes@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await cli.run(["config",key,value])}
        return(root,cli)
    }
    private func fixture()async throws->Fixture {
        let(root,cli)=try await initial()
        try Data("committed\n".utf8).write(to:root.appendingPathComponent("tracked"));try await cli.stage(["tracked"]);_=try await cli.commit(message:"notes baseline")
        let head=String(decoding:try await cli.run(["rev-parse","HEAD"]).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
        try Data("unrelated working changes\n".utf8).write(to:root.appendingPathComponent("tracked"))
        return .init(root:root,cli:cli,head:head)
    }
    private func witness(_ f:Fixture)async throws->Witness {
        .init(head:try await f.cli.run(["rev-parse","HEAD"]).stdout,index:try Data(contentsOf:f.root.appendingPathComponent(".git/index")),working:try Data(contentsOf:f.root.appendingPathComponent("tracked")),config:try Data(contentsOf:f.root.appendingPathComponent(".git/config")))
    }
    private func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func script(_ root:URL,_ name:String,_ body:String)throws->URL {
        let file=root.appendingPathComponent(".git/"+name);try Data(("#!/bin/sh\n"+body).utf8).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path);return file
    }
    private func noteBytes(_ f:Fixture,ref:String="refs/notes/commits")async throws->Data {
        let blob=String(decoding:try await f.cli.run(["notes","--ref="+ref,"list",f.head]).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
        return try await f.cli.run(["cat-file","blob",blob]).stdout
    }
    func testSourceNotesUseHelperRegardlessOfMasterAndCommandMask()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let missing=f.root.appendingPathComponent("missing-helper")
        for enabled in [false,true] {
            do{_=try await repository(f.root,enabled:enabled,helper:missing).editableCommitNote(revision:f.head);XCTFail("Unconditional source note read fell back to CLI")}
            catch GitLibGit2Failure.runtimeMissing{}
        }
    }
    func testExactUnicodeWhitespaceAndEmptyNoteRemainStoredWithoutChangingSourceState()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let before=try await witness(f),repo=repository(f.root,enabled:false)
        let empty=try await repo.editableCommitNote(revision:f.head)
        XCTAssertEqual(empty.text,"");XCTAssertEqual(empty.notesRef,"refs/notes/commits")
        let text="  leading\n# literal\r\nCafe\u{301} 雪😀\n\ntrailing  "
        let returned=try await repo.saveCommitNote(empty,text:text)
        XCTAssertEqual(Data(returned.utf8),Data(text.utf8))
        let loaded=try await repo.editableCommitNote(revision:f.head),bytes=try await noteBytes(f)
        XCTAssertEqual(Data(loaded.text.utf8),Data(text.utf8));XCTAssertEqual(bytes,Data(text.utf8))
        _=try await repo.saveCommitNote(loaded,text:"")
        let retained=try await noteBytes(f);XCTAssertTrue(retained.isEmpty)
        let after=try await witness(f);XCTAssertEqual(after,before)
    }
    func testConfiguredDefaultRefIgnoresEnvironmentAndDisplayOnlyRefs()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _=try await f.cli.run(["config","core.notesRef","refs/notes/configured"])
        _=try await f.cli.run(["config","notes.displayRef","refs/notes/display"])
        _=try await f.cli.run(["notes","--ref=refs/notes/display","add","-m","display only",f.head])
        _=try await f.cli.run(["notes","--ref=refs/notes/environment","add","-m","environment only",f.head])
        let helper=try script(f.root,"notes-environment","export GIT_NOTES_REF=refs/notes/environment\nexec "+quote(runtime.path)+" \"$@\"\n")
        let repo=repository(f.root,helper:helper),note=try await repo.editableCommitNote(revision:f.head)
        XCTAssertEqual(note.notesRef,"refs/notes/configured");XCTAssertEqual(note.text,"")
        _=try await repo.saveCommitNote(note,text:"configured exact note")
        let written=try await noteBytes(f,ref:"refs/notes/configured"),untouched=try await noteBytes(f,ref:"refs/notes/environment")
        XCTAssertEqual(written,Data("configured exact note".utf8));XCTAssertEqual(untouched,Data("environment only\n".utf8))
    }
    func testNotesCommitUsesOneConfigSignatureAndCurrentTimeDespiteIdentityOverrides()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        for(key,value)in[("author.name","Other Config Author"),("author.email","author@example.invalid"),("committer.name","Other Config Committer"),("committer.email","committer@example.invalid")]{_=try await f.cli.run(["config",key,value])}
        let helper=try script(f.root,"identity-overrides","export GIT_AUTHOR_NAME='Environment Author' GIT_AUTHOR_EMAIL=env-author@example.invalid GIT_COMMITTER_NAME='Environment Committer' GIT_COMMITTER_EMAIL=env-committer@example.invalid GIT_AUTHOR_DATE='2001-01-01T00:00:00+00:00' GIT_COMMITTER_DATE='2002-01-01T00:00:00+00:00'\nexec "+quote(runtime.path)+" \"$@\"\n")
        let repo=repository(f.root,helper:helper),note=try await repo.editableCommitNote(revision:f.head),lower=Int(Date().timeIntervalSince1970)-2
        _=try await repo.saveCommitNote(note,text:"source identity")
        let data=try await f.cli.run(["show","--no-patch","--format=%an%x00%ae%x00%cn%x00%ce%x00%at%x00%ct",note.notesRef]).stdout
        let fields=String(decoding:data,as:UTF8.self).trimmingCharacters(in:.newlines).components(separatedBy:"\0")
        XCTAssertEqual(fields.count,6);guard fields.count==6 else{return}
        XCTAssertEqual(Array(fields.prefix(4)),["Config Notes Author","config-notes@example.invalid","Config Notes Author","config-notes@example.invalid"])
        let author=try XCTUnwrap(Int(fields[4])),committer=try XCTUnwrap(Int(fields[5]))
        XCTAssertEqual(author,committer);XCTAssertGreaterThanOrEqual(author,lower);XCTAssertLessThanOrEqual(author,Int(Date().timeIntervalSince1970)+2)
    }
    func testCapturedNotesRefSurvivesLaterConfigurationChange()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _=try await f.cli.run(["config","core.notesRef","refs/notes/accepted"])
        let repo=repository(f.root),note=try await repo.editableCommitNote(revision:f.head)
        _=try await f.cli.run(["config","core.notesRef","refs/notes/later"])
        _=try await repo.saveCommitNote(note,text:"accepted target")
        let bytes=try await noteBytes(f,ref:"refs/notes/accepted"),later=try await f.cli.run(["show-ref","--verify","--quiet","refs/notes/later"],successfulExitCodes:0...1)
        XCTAssertEqual(bytes,Data("accepted target".utf8));XCTAssertEqual(later.exitCode,1)
    }
    func testMinimumLengthCountsUTF16AndInvalidTextDoesNotPublishNotes()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _=try await f.cli.run(["config","tgit.logminsize","4"])
        let repo=repository(f.root),note=try await repo.editableCommitNote(revision:f.head)
        XCTAssertEqual(note.minimumLength,4);XCTAssertFalse(note.accepts("abc"));XCTAssertTrue(note.accepts("😀😀"))
        do{_=try await repo.saveCommitNote(note,text:"abc");XCTFail("Too-short note accepted")}catch CommitNoteFailure.minimumLength(let value){XCTAssertEqual(value,4)}
        do{_=try await repo.saveCommitNote(note,text:"four\0bytes");XCTFail("NUL note accepted")}catch CommitNoteFailure.invalidText{}
        let absent=try await f.cli.run(["show-ref","--verify","--quiet",note.notesRef],successfulExitCodes:0...1);XCTAssertEqual(absent.exitCode,1)
        _=try await repo.saveCommitNote(note,text:"😀😀")
        let bytes=try await noteBytes(f);XCTAssertEqual(bytes,Data("😀😀".utf8))
    }
    func testMalformedExistingNoteDoesNotBecomeBlankEditableDraft()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        for bytes in [Data([0xff,0xfe]),Data("note\0hidden".utf8)] {
            let blob=String(decoding:try await f.cli.run(["hash-object","-w","--stdin"],input:bytes).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
            _=try await f.cli.run(["notes","add","--force","--allow-empty","--reuse-message",blob,f.head])
            do{_=try await repository(f.root).editableCommitNote(revision:f.head);XCTFail("Malformed note opened as editable text")}catch CommitNoteFailure.invalidText{}
        }
    }
    func testReadingWithoutIdentityRemainsSeparateFromWriteSignatureFailure()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _=try await f.cli.run(["config","user.name",""]);_=try await f.cli.run(["config","user.email",""])
        let repo=repository(f.root),note=try await repo.editableCommitNote(revision:f.head)
        let preflight=try await repo.replayUserIdentity(environment:["GIT_AUTHOR_NAME":"UI author","GIT_AUTHOR_EMAIL":"ui@example.invalid","GIT_COMMITTER_NAME":"UI committer","GIT_COMMITTER_EMAIL":"committer@example.invalid"])
        XCTAssertTrue(preflight.complete,"Environment-aware source UI preflight is separate from note signature creation")
        XCTAssertEqual(note.text,"")
        do{_=try await repo.saveCommitNote(note,text:"cannot manufacture signature");XCTFail("Source default signature was invented from environment/fallback")}
        catch let failure as GitFailure {XCTAssertNotEqual(failure.code,0)}
        let absent=try await f.cli.run(["show-ref","--verify","--quiet",note.notesRef],successfulExitCodes:0...1);XCTAssertEqual(absent.exitCode,1)
    }
    func testUnbornAndMissingRevisionCannotCreateNotesOnInventedCommit()async throws {
        let(root,_)=try await initial();defer{try? FileManager.default.removeItem(at:root)}
        let repo=repository(root)
        for revision in ["HEAD","refs/heads/absent",String(repeating:"a",count:40)] {
            do{_=try await repo.editableCommitNote(revision:revision);XCTFail("Unavailable note target accepted")}
            catch GitNotesEngineFailure.revision{}
        }
        let absent=try await repo.run(["show-ref","--verify","--quiet","refs/notes/commits"],successfulExitCodes:0...1);XCTAssertEqual(absent.exitCode,1)
    }
    func testPrecancelledNotesReadAndSaveNeverLaunchOwnedHelper()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let marker=f.root.appendingPathComponent("unexpected-notes-launch"),helper=try script(f.root,"must-not-launch","touch "+quote(marker.path)+"\nexit 77\n")
        let repo=repository(f.root,helper:helper),token=OperationCancellation();token.cancel()
        do{_=try await repo.editableCommitNote(revision:f.head,cancellation:token);XCTFail("Precancelled note read accepted")}catch is OperationCancellationFailure{}
        let captured=try await repository(f.root).editableCommitNote(revision:f.head)
        do{_=try await repo.saveCommitNote(captured,text:"no write",cancellation:token);XCTFail("Precancelled note save accepted")}catch is OperationCancellationFailure{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }
    func testLiveNoteReadCancellationDrainsActualOwnedHelper()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let marker=f.root.appendingPathComponent("notes-owned.pid"),input=f.root.appendingPathComponent("notes-owned-input")
        let hold="cat > "+quote(input.path)+"\nfor arg in \"$@\"; do verb=$arg; done\nif [ \"$verb\" = turtlegit-notes-read ]; then\nprintf '%s\\n' $$ > "+quote(marker.path+".tmp")+"\nmv "+quote(marker.path+".tmp")+" "+quote(marker.path)+"\nexec /bin/sleep 30\nfi\nexec "+quote(runtime.path)+" \"$@\" < "+quote(input.path)+"\n"
        let helper=try script(f.root,"held-notes",hold)
        let token=OperationCancellation(),repo=repository(f.root,helper:helper),before=try await witness(f)
        let task=Task{try await repo.editableCommitNote(revision:f.head,cancellation:token)}
        for _ in 0..<400 {if FileManager.default.fileExists(atPath:marker.path){break};try? await Task.sleep(nanoseconds:10_000_000)}
        let started=FileManager.default.fileExists(atPath:marker.path);token.cancel()
        do{_=try await task.value;XCTFail("Cancelled note helper completed")}
        catch is OperationCancellationFailure {XCTAssertTrue(token.isCancelled)}
        catch is GitCommandCancellationFailure {XCTAssertTrue(token.isCancelled)}
        XCTAssertTrue(started,"Actual selected note helper never started")
        if started {let pid=try XCTUnwrap(Int32(String(contentsOf:marker,encoding:.utf8).trimmingCharacters(in:.newlines)));errno=0;XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)}
        let after=try await witness(f);XCTAssertEqual(after,before)
    }

    func testNotesReadAndMutationSchedulingRemainDistinctWithExplicitRefValues() {
        for args in [["turtlegit-notes-read"],["notes"],["notes","get-ref"],["notes","list","HEAD"],["notes","--ref=refs/notes/review","show","HEAD"],["notes","--ref","add","list","HEAD"],["notes","--ref","add"]] {
            XCTAssertFalse(FinderStatusOperationLease.isCommandActivity(args),"Read-only Notes command acquired mutation fence: \(args)")
        }
        for args in [["turtlegit-notes-write"],["notes","add","HEAD"],["notes","--ref=refs/notes/review","add","--force","HEAD"],["notes","--ref","add","add","HEAD"],["notes","remove","HEAD"]] {
            XCTAssertTrue(FinderStatusOperationLease.isCommandActivity(args),"Notes mutation escaped operation fence: \(args)")
        }
    }

    func testMalformedNotesRepliesCannotBecomeBlankEditorsOrCLIFallback()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let lookup=try JSONSerialization.data(withJSONObject:["operation":"revision","oid":f.head,"unbornHead":false]).base64EncodedString()
        let good:[String:Any]=["notesRef":"refs/notes/commits","text":"","blobOID":NSNull(),"refOID":NSNull()]
        var extra=good;extra["extra"]=true
        var badText=good;badText["text"]="not base64!"
        var badOID=good;badOID["blobOID"]="invalid-object-id"
        var wideOID=good;wideOID["refOID"]=String(repeating:"a",count:64)
        var incoherent=good;incoherent["blobOID"]=f.head
        var replies=["invalid notes framing\n"]
        for payload in [extra,badText,badOID,wideOID,incoherent] {replies.append("TurtleGit Notes v1:"+(try JSONSerialization.data(withJSONObject:payload)).base64EncodedString()+"\n")}
        replies.append("TurtleGit Notes v1:"+(try JSONSerialization.data(withJSONObject:good)).base64EncodedString()+"\n\n")
        let before=try await witness(f)
        for reply in replies {
            let body="cat >/dev/null\nfor arg in \"$@\"; do verb=$arg; done\ncase \"$verb\" in\nturtlegit-revision-lookup) printf '%s\\n' "+quote("TurtleGit RevisionLookup v1:"+lookup)+";;\nturtlegit-notes-read) printf '%s' "+quote(reply)+";;\n*) exit 74;;\nesac\n"
            let helper=try script(f.root,"malformed-notes",body)
            do{_=try await repository(f.root,helper:helper).editableCommitNote(revision:f.head);XCTFail("Malformed Notes reply opened blank editor")}catch GitNotesEngineFailure.output{}
        }
        let after=try await witness(f);XCTAssertEqual(after,before)
    }
    func testNotesProcessFailureRetainsRealDiagnosticsWithoutFallback()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let helper=try script(f.root,"failed-notes","cat >/dev/null\nprintf 'controlled Notes read failure\\n' >&2\nexit 73\n")
        do{_=try await repository(f.root,enabled:false,helper:helper).editableCommitNote(revision:f.head);XCTFail("Failed unconditional Notes helper fell back to CLI")}
        catch let failure as GitFailure {XCTAssertEqual(failure.code,73);XCTAssertTrue(failure.message.contains("controlled Notes read failure"))}
    }
    func testFailedWriteRecoveryDistinguishesUnchangedStoredAndUncertainOutcomes()async throws {
        for mode in ["unchanged","stored","conflicting","unreadable"] {
            let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
            let helper=f.root.appendingPathComponent(".git/recovery-helper"),request=URL(fileURLWithPath:helper.path+".request"),failed=URL(fileURLWithPath:helper.path+".failed")
            let requested="requested exact note 雪\n  "
            var body="cat > "+quote(request.path)+"\nfor arg in \"$@\"; do verb=$arg; done\n"
            if mode=="unreadable" {body += "if [ -f "+quote(failed.path)+" ] && [ \"$verb\" = turtlegit-notes-read ]; then printf 'recovery read failed\\n' >&2; exit 74; fi\n"}
            body += "if [ \"$verb\" = turtlegit-notes-write ]; then\n"
            if mode=="stored" {body += quote(runtime.path)+" \"$@\" < "+quote(request.path)+" > /dev/null || exit $?\n"}
            if mode=="conflicting" {body += quote(git.path)+" --literal-pathspecs -C "+quote(f.root.path)+" notes --ref=refs/notes/commits add --force -m 'concurrent other note' "+quote(f.head)+" || exit $?\n"}
            body += "touch "+quote(failed.path)+"\nprintf 'controlled Notes write failure\\n' >&2\nexit 73\nfi\nexec "+quote(runtime.path)+" \"$@\" < "+quote(request.path)+"\n"
            _=try script(f.root,"recovery-helper",body)
            let repo=repository(f.root,helper:helper),note=try await repo.editableCommitNote(revision:f.head),before=try await witness(f)
            do{_=try await repo.saveCommitNote(note,text:requested);XCTFail("Failed mutation receipt reported ordinary success")}
            catch CommitNoteFailure.savedButRefreshFailed(let detail) {XCTAssertEqual(mode,"stored");XCTAssertTrue(detail.contains("controlled Notes write failure"))}
            catch CommitNoteFailure.saveOutcomeUnknown(let detail) {XCTAssertTrue(mode=="conflicting" || mode=="unreadable");XCTAssertTrue(detail.contains("controlled Notes write failure"))}
            catch let failure as GitFailure {XCTAssertEqual(mode,"unchanged");XCTAssertEqual(failure.code,73)}
            if mode=="stored" {let actual=try await noteBytes(f);XCTAssertEqual(actual,Data(requested.utf8))}
            else if mode=="conflicting" {let actual=try await noteBytes(f);XCTAssertEqual(actual,Data("concurrent other note\n".utf8))}
            else {let absent=try await f.cli.run(["show-ref","--verify","--quiet",note.notesRef],successfulExitCodes:0...1);XCTAssertEqual(absent.exitCode,1)}
            let after=try await witness(f);XCTAssertEqual(after,before)
        }
    }

    func testLivePrewriteCancellationPreservesPublishedNoteAndCanRetry()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let marker=f.root.appendingPathComponent("notes-write.pid"),input=f.root.appendingPathComponent("notes-write-input")
        let hold="cat > "+quote(input.path)+"\nfor arg in \"$@\"; do verb=$arg; done\nif [ \"$verb\" = turtlegit-notes-write ]; then\nprintf '%s\\n' $$ > "+quote(marker.path+".tmp")+"\nmv "+quote(marker.path+".tmp")+" "+quote(marker.path)+"\nexec /bin/sleep 30\nfi\nexec "+quote(runtime.path)+" \"$@\" < "+quote(input.path)+"\n"
        let helper=try script(f.root,"held-notes-write",hold),repo=repository(f.root,helper:helper)
        let note=try await repo.editableCommitNote(revision:f.head),token=OperationCancellation(),before=try await witness(f)
        let task=Task{try await repo.saveCommitNote(note,text:"never published",cancellation:token)}
        for _ in 0..<400 {if FileManager.default.fileExists(atPath:marker.path){break};try? await Task.sleep(nanoseconds:10_000_000)}
        let started=FileManager.default.fileExists(atPath:marker.path);token.cancel()
        do{_=try await task.value;XCTFail("Cancelled prewrite returned success")}
        catch is OperationCancellationFailure {XCTAssertTrue(token.isCancelled)}
        catch is GitCommandCancellationFailure {XCTAssertTrue(token.isCancelled)}
        XCTAssertTrue(started)
        if started {let pid=try XCTUnwrap(Int32(String(contentsOf:marker,encoding:.utf8).trimmingCharacters(in:.newlines)));errno=0;XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)}
        let direct=repository(f.root),reread=try await direct.editableCommitNote(revision:f.head),after=try await witness(f)
        XCTAssertEqual(reread.text,"");XCTAssertEqual(after,before)
        _=try await direct.saveCommitNote(reread,text:"independent retry")
        let bytes=try await noteBytes(f);XCTAssertEqual(bytes,Data("independent retry".utf8))
    }

    func testTornRecoveryReceiptsCannotFalselyConfirmSavedNote()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let requested="accepted note",other="concurrent replacement"
        let expected=String(decoding:try await f.cli.run(["hash-object","--stdin"],input:Data(requested.utf8)).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
        let otherOID=String(decoding:try await f.cli.run(["hash-object","--stdin"],input:Data(other.utf8)).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
        func frame(_ text:String,_ oid:String)throws->String {
            "TurtleGit Notes v1:"+(try JSONSerialization.data(withJSONObject:["notesRef":"refs/notes/commits","text":Data(text.utf8).base64EncodedString(),"blobOID":oid,"refOID":f.head])).base64EncodedString()+"\n"
        }
        let first=try frame(requested,expected),settled=try frame(other,otherOID)
        let helper=f.root.appendingPathComponent(".git/torn-recovery"),input=URL(fileURLWithPath:helper.path+".request"),failed=URL(fileURLWithPath:helper.path+".failed"),seen=URL(fileURLWithPath:helper.path+".seen")
        let body="cat > "+quote(input.path)+"\nfor arg in \"$@\"; do verb=$arg; done\nif [ \"$verb\" = turtlegit-notes-write ]; then touch "+quote(failed.path)+";printf 'torn receipt write failure\\n' >&2;exit 73;fi\nif [ \"$verb\" = turtlegit-notes-read ] && [ -f "+quote(failed.path)+" ]; then\nif [ -f "+quote(seen.path)+" ]; then printf '%s' "+quote(settled)+";else touch "+quote(seen.path)+";printf '%s' "+quote(first)+";fi\nexit 0\nfi\nexec "+quote(runtime.path)+" \"$@\" < "+quote(input.path)+"\n"
        _=try script(f.root,"torn-recovery",body)
        let repo=repository(f.root,helper:helper),note=try await repo.editableCommitNote(revision:f.head)
        do{_=try await repo.saveCommitNote(note,text:requested);XCTFail("Contradictory recovery receipts certified a stored note")}
        catch CommitNoteFailure.saveOutcomeUnknown(let detail){XCTAssertTrue(detail.contains("torn receipt write failure"))}
        let absent=try await f.cli.run(["show-ref","--verify","--quiet",note.notesRef],successfulExitCodes:0...1);XCTAssertEqual(absent.exitCode,1)
    }
    func testMaximumNoteWithBase64SlashesRoundTripsAndExcessIsRefusedBeforeMutation()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let text=String(repeating:"\u{ffff}",count:5_592_405)+"x"
        XCTAssertEqual(text.utf8.count,16_777_216)
        let repo=repository(f.root),note=try await repo.editableCommitNote(revision:f.head),before=try await witness(f)
        let returned=try await repo.saveCommitNote(note,text:text)
        XCTAssertEqual(Data(returned.utf8),Data(text.utf8))
        let bytes=try await noteBytes(f);XCTAssertEqual(bytes,Data(text.utf8))
        do{_=try await repo.saveCommitNote(note,text:text+"x");XCTFail("Note above raw-byte ceiling was accepted")}catch CommitNoteFailure.invalidText{}
        let retained=try await noteBytes(f);XCTAssertEqual(retained,bytes)
        let after=try await witness(f);XCTAssertEqual(after,before)
    }

    func testIdenticalExistingNoteDoesNotTurnSignatureFailureIntoConfirmedPublication()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let repo=repository(f.root),initial=try await repo.editableCommitNote(revision:f.head),text="already published content"
        _=try await repo.saveCommitNote(initial,text:text)
        let refBefore=try await f.cli.run(["rev-parse",initial.notesRef]).stdout
        _=try await f.cli.run(["config","user.name",""]);_=try await f.cli.run(["config","user.email",""])
        let note=try await repo.editableCommitNote(revision:f.head)
        do{_=try await repo.saveCommitNote(note,text:text);XCTFail("Signature failure certified a new identical-content write")}
        catch let failure as GitFailure {XCTAssertNotEqual(failure.code,0)}
        let refAfter=try await f.cli.run(["rev-parse",note.notesRef]).stdout,bytes=try await noteBytes(f)
        XCTAssertEqual(refAfter,refBefore);XCTAssertEqual(bytes,Data(text.utf8))
    }

}
