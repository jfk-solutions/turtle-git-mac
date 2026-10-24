import XCTest
@testable import TurtleGitCore

final class PushDestinationTests:XCTestCase {
    private struct Fixture {
        let root:URL,repo:GitRepository,remote:GitRepository,base:String,head:String
    }
    private func fixture()async throws->Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitPushDestination-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,askpass:nil,libgit2Configuration:.init(enabled:false)),remoteURL=root.appendingPathComponent("remote.git")
        _=try await repo.run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Push destination QA"),("user.email","destination@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try FileManager.default.createDirectory(at:remoteURL,withIntermediateDirectories:true)
        let remote=GitRepository(root:remoteURL,askpass:nil,libgit2Configuration:.init(enabled:false));_=try await remote.run(["init","--bare","--template="])
        _=try await repo.run(["remote","add","origin",remoteURL.path]);_=try await repo.run(["push","origin","refs/heads/main:refs/heads/main"])
        try Data("next\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"next")
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        return Fixture(root:root,repo:repo,remote:remote,base:base,head:head)
    }
    private func ref(_ repo:GitRepository,_ name:String)async throws->String? {
        let result=try await repo.run(["show-ref","--verify","--quiet","--",name],successfulExitCodes:0...1)
        guard result.exitCode==0 else{return nil}
        return try await repo.run(["rev-parse","--verify","--end-of-options",name]).text.trimmingCharacters(in:.newlines)
    }
    private func options(source:String="refs/heads/main",destination:String)->PushOptions {
        var value=PushOptions();value.remote="origin";value.source=source;value.destination=destination;return value
    }
    func testBranchAndHashUpdateUniqueExistingShortRemoteTagWithoutInventingBranch()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let index=try Data(contentsOf:f.root.appendingPathComponent(".git/index"))
        for (source,name) in [("refs/heads/main","branch-target"),(f.head,"hash-target")] {
            _=try await f.remote.run(["update-ref","refs/tags/"+name,f.base])
            var value=options(source:source,destination:name);value.force=true
            _=try await f.repo.push(value)
            let tag=try await ref(f.remote,"refs/tags/"+name),branch=try await ref(f.remote,"refs/heads/"+name)
            XCTAssertEqual(tag,f.head);XCTAssertNil(branch,"A literal tag destination was rewritten to heads")
        }
        let head=try await ref(f.repo,"refs/heads/main");XCTAssertEqual(head,f.head)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
    }
    func testShortAndQualifiedRemoteTagDeletionKeepUnrelatedBranches()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        for (name,destination) in [("short-delete","short-delete"),("full-delete","refs/tags/full-delete")] {
            _=try await f.remote.run(["update-ref","refs/tags/"+name,f.base])
            _=try await f.repo.push(options(source:"",destination:destination))
            let tag=try await ref(f.remote,"refs/tags/"+name);XCTAssertNil(tag)
        }
        let original=try await ref(f.remote,"refs/heads/main");XCTAssertEqual(original,f.base)
    }
    func testAmbiguousShortDestinationFailsWithoutMutationAndQualifiedDestinationsEscape()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        for name in ["refs/heads/collision","refs/tags/collision"] {_=try await f.remote.run(["update-ref",name,f.base])}
        var value=options(destination:"collision");value.force=true
        do {_=try await f.repo.push(value);XCTFail("Ambiguous remote namespace was silently chosen")}
        catch let failure as PushExecutionFailure {
            XCTAssertEqual(failure.failedRemote,"origin");XCTAssertTrue(failure.completed.isEmpty)
            XCTAssertTrue(failure.commandFailure?.arguments.contains("refs/heads/main:collision")==true)
        }
        let branch=try await ref(f.remote,"refs/heads/collision"),tag=try await ref(f.remote,"refs/tags/collision")
        XCTAssertEqual(branch,f.base);XCTAssertEqual(tag,f.base)
        value.destination="refs/tags/collision";_=try await f.repo.push(value)
        let newTag=try await ref(f.remote,"refs/tags/collision"),oldBranch=try await ref(f.remote,"refs/heads/collision")
        XCTAssertEqual(newTag,f.head);XCTAssertEqual(oldBranch,f.base)
        value.destination="refs/heads/collision";_=try await f.repo.push(value)
        let newBranch=try await ref(f.remote,"refs/heads/collision");XCTAssertEqual(newBranch,f.head)
        value.source="";value.destination="collision"
        do {_=try await f.repo.push(value);XCTFail("Ambiguous deletion selected a namespace")}
        catch let failure as PushExecutionFailure {XCTAssertTrue(failure.commandFailure?.arguments.contains(":collision")==true)}
        let preservedBranch=try await ref(f.remote,"refs/heads/collision"),preservedTag=try await ref(f.remote,"refs/tags/collision")
        XCTAssertEqual(preservedBranch,f.head);XCTAssertEqual(preservedTag,f.head)
    }
    func testRawRevisionRequiresQualifiedNewDestinationAndPreflightDoesNotGuess()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var value=options(source:f.head,destination:"new-hash-target")
        try await f.repo.validatePushOptions(value)
        do {_=try await f.repo.push(value);XCTFail("A new namespace was invented for a raw revision")}
        catch let failure as PushExecutionFailure {XCTAssertTrue(failure.commandFailure?.arguments.contains(f.head+":new-hash-target")==true)}
        let absent=try await ref(f.remote,"refs/heads/new-hash-target");XCTAssertNil(absent)
        value.destination="refs/heads/new-hash-target";_=try await f.repo.push(value)
        let branch=try await ref(f.remote,"refs/heads/new-hash-target");XCTAssertEqual(branch,f.head)
    }
    func testURLAndAllRemotesResolveLiteralDestinationPerServerAndReportPartialFailure()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _=try await f.remote.run(["update-ref","refs/tags/url-tag",f.base])
        var urlValue=options(destination:"url-tag");urlValue.remote=f.remote.root.path;urlValue.arbitraryURL=true;urlValue.force=true
        _=try await f.repo.push(urlValue)
        let tag=try await ref(f.remote,"refs/tags/url-tag"),branch=try await ref(f.remote,"refs/heads/url-tag")
        XCTAssertEqual(tag,f.head);XCTAssertNil(branch)
        _=try await f.repo.run(["remote","rename","origin","a-tag"])
        let secondURL=f.root.appendingPathComponent("second remote.git");try FileManager.default.createDirectory(at:secondURL,withIntermediateDirectories:true)
        let second=GitRepository(root:secondURL,askpass:nil,libgit2Configuration:.init(enabled:false));_=try await second.run(["init","--bare","--template="])
        _=try await f.repo.run(["remote","add","z-ambiguous",secondURL.path]);_=try await f.repo.run(["push","z-ambiguous",f.base+":refs/heads/main"])
        _=try await f.remote.run(["update-ref","refs/tags/common",f.base])
        for name in ["refs/heads/common","refs/tags/common"] {_=try await second.run(["update-ref",name,f.base])}
        var all=options(destination:"common");all.allRemotes=true;all.force=true
        do {_=try await f.repo.push(all);XCTFail("Later ambiguous server unexpectedly accepted push")}
        catch let failure as PushExecutionFailure {XCTAssertEqual(failure.completed,["a-tag"]);XCTAssertEqual(failure.failedRemote,"z-ambiguous")}
        let firstTag=try await ref(f.remote,"refs/tags/common"),firstBranch=try await ref(f.remote,"refs/heads/common")
        XCTAssertEqual(firstTag,f.head);XCTAssertNil(firstBranch)
        for name in ["refs/heads/common","refs/tags/common"] {let unchanged=try await ref(second,name);XCTAssertEqual(unchanged,f.base)}
    }
    func testSavedBranchDefaultsRetainLiteralDestinationEvenWhenTransportRejects()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        for name in ["refs/heads/collision","refs/tags/collision"] {_=try await f.remote.run(["update-ref",name,f.base])}
        var value=options(source:"main",destination:"collision");value.savePushRemote=true;value.savePushBranch=true
        do {_=try await f.repo.push(value);XCTFail("Ambiguous transport unexpectedly succeeded")}
        catch is PushExecutionFailure {}
        let branch=try await f.repo.run(["config","--get","branch.main.pushbranch"]).text,remote=try await f.repo.run(["config","--get","branch.main.pushremote"]).text
        XCTAssertEqual(branch,"collision\n");XCTAssertEqual(remote,"origin\n")
        let index=try Data(contentsOf:f.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:f.root.appendingPathComponent(".git/config"))
        let cancelled=OperationCancellation();cancelled.cancel();value.destination="refs/heads/should-not-appear"
        do {_=try await f.repo.push(value,cancellation:cancelled);XCTFail("Cancelled request wrote config or refs")}
        catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/config")),config);XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
        let absent=try await ref(f.remote,"refs/heads/should-not-appear");XCTAssertNil(absent)
    }
    func testNonShortBranchSaveOptionsAreAcceptedNoOpAndUpstreamFlagIsForwarded()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _=try await f.repo.run(["tag","tag-source"])
        let config=try Data(contentsOf:f.root.appendingPathComponent(".git/config"))
        for (source,destination) in [("refs/tags/tag-source","refs/tags/saved-tag"),(f.head,"refs/heads/saved-hash"),("HEAD","refs/heads/saved-head"),("main~0","refs/heads/saved-revision"),("refs/heads/main","refs/heads/saved-qualified")] {
            var value=options(source:source,destination:destination);value.savePushRemote=true;value.savePushBranch=true
            try await f.repo.validatePushOptions(value);_=try await f.repo.push(value)
            XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/config")),config,"Nonbranch source created branch configuration")
        }
        var tracked=options(source:"refs/tags/tag-source",destination:"refs/tags/upstream-tag");tracked.setUpstream=true
        _=try await f.repo.push(tracked)
        let tag=try await ref(f.remote,"refs/tags/upstream-tag");XCTAssertEqual(tag,f.head)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/config")),config)
    }
    func testUnicodeSourceAndDestinationAndTransportFlagsAreForwardedExactly()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let source="refs/tags/café",destination="literal-雪/cafe\u{301}"
        _=try await f.repo.run(["update-ref",source,f.head])
        _=try await f.remote.run(["config","receive.advertisePushOptions","true"])
        let hooks=f.remote.root.appendingPathComponent("hooks"),hook=hooks.appendingPathComponent("pre-receive")
        try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:true)
        _=try await f.remote.run(["config","core.hooksPath",hooks.path])
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to:hook);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:hook.path)
        var value=options(source:source,destination:destination);value.forceWithLease=true;value.setUpstream=true;value.submodules = .check;value.pushOption="literal = option"
        do {_=try await f.repo.push(value);XCTFail("Private rejecting server accepted push")}
        catch let failure as PushExecutionFailure {
            let arguments=try XCTUnwrap(failure.commandFailure?.arguments)
            XCTAssertTrue(arguments.last?.utf8.elementsEqual((source+":"+destination).utf8)==true,"Source/destination Unicode spelling or namespace changed")
            for flag in ["--porcelain","--progress","--force-with-lease","--set-upstream","--recurse-submodules=check","--push-option=literal = option"] {XCTAssertTrue(arguments.contains(flag),flag)}
        }
        let unexpected=try await ref(f.remote,"refs/tags/"+destination);XCTAssertNil(unexpected)
    }

}
