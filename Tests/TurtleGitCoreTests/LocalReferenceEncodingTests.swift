import XCTest
@testable import TurtleGitCore

final class LocalReferenceEncodingTests:XCTestCase {
    private func fixture()async throws->(URL,GitRepository,String,String) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitReferenceEncoding-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let git=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_QA_GIT"] ?? "/usr/bin/git")
        let repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:true,mask:GitLibGit2Operation.forEachRef.mask))
        do {
            _=try await repo.run(["init","--template=","-b","main"])
            for(k,v)in[("user.name","Encoding QA"),("user.email","encoding@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_=try await repo.run(["config",k,v])}
            try Data("unchanged\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
            let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),tree=try await repo.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
            return(root,repo,head,tree)
        }catch{try? FileManager.default.removeItem(at:root);throw error}
    }
    private func commit(_ repo:GitRepository,tree:String,encoding:String?,name:Data=Data("Author".utf8),email:Data=Data("author@example.invalid".utf8),message:Data)async throws->(String,Data) {
        var bytes=Data(("tree "+tree+"\nauthor ").utf8);bytes.append(name);bytes.append(Data(" <".utf8));bytes.append(email);bytes.append(Data("> 123 +0000\ncommitter ".utf8));bytes.append(name);bytes.append(Data(" <".utf8));bytes.append(email);bytes.append(Data("> 124 +0000\n".utf8))
        if let encoding{bytes.append(Data(("encoding "+encoding+"\n").utf8))};bytes.append(10);bytes.append(message)
        let oid=try await repo.run(["hash-object","-t","commit","-w","--stdin"],input:bytes).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["update-ref","refs/heads/encoded",oid]);return(oid,bytes)
    }
    private func catalog(_ repo:GitRepository)async throws->[GitLocalReferenceRecord] {try await repo.localReferenceCatalog(backend:.init(enabled:true,mask:GitLibGit2Operation.forEachRef.mask),cancellation:nil)}
    func testDeclaredWindows1252ConvertsSummaryAndBothSignaturesWithoutChangingObjects()async throws {
        let(root,repo,_,tree)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let name=Data([0x41,0x6e,0x64,0x72,0xe9]),email=Data("andr".utf8)+Data([0xe9])+Data("@example.invalid".utf8)
        let(oid,bytes)=try await commit(repo,tree:tree,encoding:"windows-1252",name:name,email:email,message:Data("caf".utf8)+Data([0xe9])+Data(" summary\ncontinued line\n\nbody\n".utf8))
        let rows=try await catalog(repo);let row=try XCTUnwrap(rows.first{$0.name=="refs/heads/encoded"})
        XCTAssertEqual(row.subject,"café summary continued line");XCTAssertEqual(row.authorName,"André");XCTAssertEqual(row.committerName,"André");XCTAssertEqual(row.authorEmail,"andré@example.invalid");XCTAssertEqual(row.committerEmail,"andré@example.invalid")
        let raw=try await repo.run(["cat-file","commit",oid]).stdout;XCTAssertEqual(raw,bytes)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("file")),Data("unchanged\n".utf8))
    }
    func testUnknownEvenIconvKnownLabelUsesCoreUTF8Fallback()async throws {
        let(root,repo,_,tree)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let message=Data("caf".utf8)+Data([0xe9]);_=try await commit(repo,tree:tree,encoding:"MACROMAN",message:message)
        let rows=try await catalog(repo);let row=try XCTUnwrap(rows.first{$0.name=="refs/heads/encoded"})
        XCTAssertEqual(row.subject,try CommitMessageEncoding.decode(message,name:"MACROMAN"));XCTAssertEqual(row.subject,"caf�")
    }
    func testUTF8FallbackUsesMaximalSubpartsAndRetainsValidUnicode()async throws {
        let(root,repo,_,tree)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let message=Data([0xe1,0x80,0x78,0xff])+Data(" 雪".utf8);_=try await commit(repo,tree:tree,encoding:nil,message:message)
        let rows=try await catalog(repo);let row=try XCTUnwrap(rows.first{$0.name=="refs/heads/encoded"})
        XCTAssertEqual(row.subject,String(decoding:message,as:UTF8.self));XCTAssertEqual(row.subject,"�x� 雪")
    }
    func testTagWithoutCharsetUsesReplacementForDisplayButPreservesRawTag()async throws {
        let(root,repo,head,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        var bytes=Data(("object "+head+"\ntype commit\ntag invalid-display\ntagger Andr").utf8);bytes.append(0xe9);bytes.append(Data(" <tag@example.invalid> 123 +0000\n\nbad".utf8));bytes.append(0xe9);bytes.append(Data("\nsecond\n".utf8))
        let oid=try await repo.run(["hash-object","-t","tag","-w","--stdin"],input:bytes).text.trimmingCharacters(in:.newlines);_=try await repo.run(["update-ref","refs/tags/invalid-display",oid])
        let rows=try await catalog(repo);let row=try XCTUnwrap(rows.first{$0.name=="refs/tags/invalid-display"});XCTAssertEqual(row.subject,"bad�");XCTAssertEqual(row.authorName,"Andr�");XCTAssertEqual(row.committerName,"Andr�");XCTAssertEqual(row.oid,oid)
        let actual=try await repo.run(["cat-file","tag",oid]).stdout;XCTAssertEqual(actual,bytes)
    }
    func testMalformedRecognizedLegacyEncodingRefusesInventoryWithoutFallback()async throws {
        let(root,repo,_,tree)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=try await commit(repo,tree:tree,encoding:"shift_jis",message:Data([0x82]))
        do{_=try await catalog(repo);XCTFail("Malformed declared legacy text silently fell back")}
        catch let error as GitFailure{XCTAssertTrue(error.message.contains("declared commit encoding"),error.message)}
    }
    func testInvalidUTF8ReferenceNameStillRefusesStrictWire()async throws {
        let(root,repo,head,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        var packed=Data((head+" refs/heads/raw").utf8);packed.append(0xff);packed.append(10);try packed.write(to:root.appendingPathComponent(".git/packed-refs"))
        do{_=try await catalog(repo);XCTFail("Display replacement leaked into literal reference names")}
        catch let error as GitFailure{XCTAssertTrue(error.message.contains("Invalid transfer metadata"),error.message)}
    }
}
