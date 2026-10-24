// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class ReflogReferenceIdentityTests:XCTestCase {
    private let composed="refs/heads/caf\u{e9}",decomposed="refs/heads/cafe\u{301}"
    private func fixture()async throws->(URL,GitRepository,String) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitRefLogIdentity-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let git=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_QA_GIT"] ?? "/usr/bin/git")
        let repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        _=try await repo.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","RefLog identity QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        let hash=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        return(root,repo,hash)
    }
    private func packed(_ root:URL,_ hash:String)throws {
        // APFS loose filenames normalize Unicode. Packed refs are the Git byte
        // container that can represent both names on this filesystem.
        let text="# pack-refs with: peeled fully-peeled sorted\n"+[composed,decomposed,"refs/heads/main"].sorted{$0.utf8.lexicographicallyPrecedes($1.utf8)}.map{hash+" "+$0+"\n"}.joined()
        try Data(text.utf8).write(to:root.appendingPathComponent(".git/packed-refs"))
    }
    func testPackedNamesAndHashMetadataRetainBothSpellingsWithoutChangingPreferences()async throws {
        let(root,repo,hash)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try packed(root,hash)
        let config=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let names=try await repo.referenceLogNames(),mapped=try await repo.referenceLogReferenceNamesByHash()
        for name in [composed,decomposed] {
            XCTAssertEqual(names.filter{GitReferenceName.equal($0,name)}.count,1)
            XCTAssertEqual(mapped[hash]?.filter{GitReferenceName.equal($0,name)}.count,1)
        }
        XCTAssertEqual(Set(names.map{GitReferenceName($0)}).count,names.count)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/config")),config)
    }
    func testEntryEqualityAndHashingRetainSelectorAndMessageBytes() {
        let hash=String(repeating:"a",count:40)
        let a=ReferenceLogEntry(hash:hash,selector:composed+"@{0}",timestamp:"123 +0000",subject:"commit: caf\u{e9}")
        let b=ReferenceLogEntry(hash:hash,selector:decomposed+"@{0}",timestamp:a.timestamp,subject:a.subject)
        let c=ReferenceLogEntry(hash:hash,selector:a.selector,timestamp:a.timestamp,subject:"commit: cafe\u{301}")
        XCTAssertNotEqual(a,b);XCTAssertNotEqual(a,c);XCTAssertEqual(Set([a,b,c]).count,3)
    }
    func testNamedDeletionKeepsCanonicallyEquivalentCurrentBranchAndPackedSiblingIndependent()async throws {
        let(root,repo,hash)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try packed(root,hash)
        _=try await repo.run(["-c","core.precomposeunicode=false","symbolic-ref","HEAD",composed])
        let entry=ReferenceLogEntry(hash:hash,selector:"HEAD@{0}",timestamp:"123 +0000",subject:"fixture")
        do {_=try await repo.prepareReferenceLogReferenceDeletion(composed,entry:entry);XCTFail("Current branch accepted")}
        catch HistoryReferenceDeletionFailure.current {}
        let snapshot=try await repo.prepareReferenceLogReferenceDeletion(decomposed,entry:entry)
        XCTAssertTrue(GitReferenceName.equal(snapshot.name,decomposed))
        _=try await repo.deleteHistoryReference(snapshot,choice:.delete)
        let names=try await repo.referenceLogNames()
        XCTAssertTrue(names.contains{GitReferenceName.equal($0,composed)});XCTAssertFalse(names.contains{GitReferenceName.equal($0,decomposed)})
        let current=try await repo.run(["-c","core.precomposeunicode=false","symbolic-ref","HEAD"]).text.trimmingCharacters(in:.newlines)
        XCTAssertTrue(GitReferenceName.equal(current,composed))
        let preference=try await repo.run(["config","--get","core.precomposeunicode"]).text;XCTAssertEqual(preference,"true\n")
    }
    func testCrossReferenceSelectorAndChangedMessageCannotPassFreshnessOrOperationSelection()async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=try await repo.run(["-c","core.precomposeunicode=false","update-ref","--create-reflog",composed,"HEAD"])
        let expected=try await repo.referenceLog(composed)
        let first=try XCTUnwrap(expected.first),foreign=decomposed+"@{0}"
        do {_=try await repo.deleteReferenceLogEntries([foreign],reference:composed,expected:expected);XCTFail("Foreign selector accepted")}
        catch ReferenceLogFailure.selection {}
        do {_=try await repo.referenceLogOperationEntries(snapshot:expected,selected:[foreign]);XCTFail("Foreign selector selected a commit")}
        catch ReferenceLogFailure.selection {}
        let altered=ReferenceLogEntry(hash:first.hash,selector:foreign,timestamp:first.timestamp,subject:first.subject)
        do {_=try await repo.deleteReferenceLogEntries([first.selector],reference:composed,expected:[altered]);XCTFail("Foreign snapshot accepted")}
        catch ReferenceLogFailure.stale {}
        let after=try await repo.referenceLog(composed);XCTAssertEqual(after,expected)
    }
    func testReadAndDeletionInvocationPreserveExactArgumentsAndLeaveStoredPrecompositionUntouched()async throws {
        let(root,repo,hash)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=try await repo.run(["-c","core.precomposeunicode=false","update-ref","--create-reflog",decomposed,"HEAD"])
        let capture=root.appendingPathComponent("arguments"),wrapper=root.appendingPathComponent("git-wrapper")
        func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let git=ProcessInfo.processInfo.environment["TURTLEGIT_QA_GIT"] ?? "/usr/bin/git"
        let body="#!/bin/sh\nprintf '%s\\0' \"$@\" >> "+quote(capture.path)+"\nprintf '\\0' >> "+quote(capture.path)+"\nexec "+quote(git)+" \"$@\"\n"
        try Data(body.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let wrapped=GitRepository(root:root,executable:wrapper,askpass:nil,libgit2Configuration:.init(enabled:false))
        let before=try Data(contentsOf:root.appendingPathComponent(".git/config")),rows=try await wrapped.referenceLog(decomposed)
        XCTAssertFalse(rows.isEmpty);XCTAssertTrue(rows.allSatisfy{GitReferenceName.removingPrefix(decomposed+"@{",from:$0.selector) != nil})
        _=try await wrapped.deleteReferenceLogEntries([rows[0].id],reference:decomposed,expected:rows)
        let arguments=try Data(contentsOf:capture).split(separator:0).map{String(decoding:$0,as:UTF8.self)}
        XCTAssertTrue(arguments.contains{GitReferenceName.equal($0,"logs/"+decomposed)})
        XCTAssertTrue(arguments.contains{GitReferenceName.equal($0,decomposed+"@{0}")})
        XCTAssertFalse(arguments.contains{GitReferenceName.equal($0,composed+"@{0}")})
        XCTAssertTrue(arguments.contains("core.precomposeunicode=false"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/config")),before)
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(head,hash)
        let token=OperationCancellation();token.cancel()
        let captured=try Data(contentsOf:capture)
        do {_=try await wrapped.referenceLog(decomposed,cancellation:token);XCTFail("Cancelled read started")}
        catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf:capture),captured)
    }
}
