// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class ReferenceCreationUnicodeTests: XCTestCase {
    func testCreateResolveSwitchDescribeAndPushKeepExactUnicode() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=try await repo.run(["config","core.precomposeUnicode","true"])
        let first=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["commit","--allow-empty","-m","second"])
        let second=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let nfc="Café",nfd="Cafe\u{301}",message="Description e\u{301}"
        // Packed refs retain distinct byte names on normalizing Mac filesystems.
        _=try await repo.run(["update-ref","refs/heads/"+nfc,first]);_=try await repo.run(["pack-refs","--all","--prune"])
        let packed=root.appendingPathComponent(".git/packed-refs")
        let original=try String(contentsOf:packed,encoding:.utf8)
        try Data((original.replacingOccurrences(of:" sorted",with:"")+second+" refs/heads/"+nfd+"\n").utf8).write(to:packed)
        var branch=ReferenceCreationOptions();branch.name="topic-e\u{301}";branch.revision="refs/heads/"+nfd;branch.message=message
        _=try await repo.createReference(branch)
        let catalog=try await repo.checkoutReferences(),created=try XCTUnwrap(catalog.first {GitReferenceName.equal($0.name,"refs/heads/"+branch.name)})
        var checkout=CheckoutOptions();checkout.revision=created.name;_=try await repo.checkout(checkout)
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(head,second)
        let symbolic=try await repo.run(["symbolic-ref","HEAD"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(Data(symbolic.utf8),Data(created.name.utf8))
        let described=try await repo.run(["-c","core.precomposeunicode=false","config","--local","--get","branch."+branch.name+".description"]).stdout
        XCTAssertEqual(described,Data((message+"\n").utf8))
        var tag=ReferenceCreationOptions();tag.isTag=true;tag.name="release-e\u{301}";tag.message="Tag e\u{301}";tag.revision="refs/heads/"+nfd
        _=try await repo.createReference(tag)
        let tags=try await repo.checkoutReferences();XCTAssertTrue(tags.contains {GitReferenceName.equal($0.name,"refs/tags/"+tag.name)})
        let body=try await repo.run(["-c","core.precomposeunicode=false","cat-file","-p","refs/tags/"+tag.name]).stdout
        XCTAssertTrue(body.suffix(Data((tag.message+"\n").utf8).count).elementsEqual(Data((tag.message+"\n").utf8)))
        let remotePath=root.appendingPathComponent("bare"),remote=GitRepository(root:remotePath,executable:repo.executable)
        try FileManager.default.createDirectory(at:remotePath,withIntermediateDirectories:true);_=try await remote.run(["init","--bare"])
        _=try await repo.run(["remote","add","origin",remotePath.path])
        var push=PushOptions();push.remote="origin";push.source="refs/tags/"+tag.name;push.destination="published"
        _=try await repo.push(push)
        let published=try await remote.run(["rev-parse","refs/tags/published^{commit}"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(published,second)
        let preference=try await repo.run(["config","--get","core.precomposeUnicode"]).text;XCTAssertEqual(preference,"true\n")
    }
    func testCanonicalOtherTypeNameDoesNotInventCollisionOrForceTarget() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=try await repo.run(["config","core.precomposeUnicode","true"])
        let first=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["tag","Café"]);_=try await repo.run(["pack-refs","--all","--prune"])
        var branch=ReferenceCreationOptions();branch.name="Cafe\u{301}";_=try await repo.createReference(branch)
        let names=try await repo.checkoutReferences();XCTAssertTrue(names.contains {GitReferenceName.equal($0.name,"refs/heads/"+branch.name)})
        let tag=try await repo.run(["rev-parse","refs/tags/Café"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(tag,first)
        do{_=try await repo.createReference(branch);XCTFail("Duplicate exact branch accepted")}catch ReferenceCreationFailure.exists{}
    }
}
