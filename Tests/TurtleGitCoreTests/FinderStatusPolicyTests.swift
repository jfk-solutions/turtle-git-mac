import XCTest
import Darwin
@testable import TurtleGitCore

final class FinderStatusPolicyTests:XCTestCase {
    private func collect(_ repo:GitRepository,_ mode:FinderOverlayCacheMode = .standard,limit:UInt32=10240,caseSensitive:Bool=true) async throws -> FinderOverlayCollection {
        try await repo.collectFinderOverlay(policy:.init(cacheMode:mode,caseSensitive:caseSensitive,contentCheckLimitKiB:limit))
    }
    private func touch(_ file:URL) throws {try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:10)],ofItemAtPath:file.path)}
    func testDefaultAndShellDistinguishStagedAddsChangesDeletesAndIgnore() async throws {
        let(root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("staged change\n".utf8).write(to:root.appendingPathComponent(path))
        try Data("new\n".utf8).write(to:root.appendingPathComponent("added"))
        try Data("gone\n".utf8).write(to:root.appendingPathComponent("deleted"));_ = try await repo.run(["add","--","deleted"]);_ = try await repo.run(["commit","-m","add deleted"])
        try Data("ignored\n".utf8).write(to:root.appendingPathComponent(".gitignore"));try Data("ignore me".utf8).write(to:root.appendingPathComponent("ignored"))
        _ = try await repo.run(["add","--",path,"added",".gitignore"]);_ = try await repo.run(["rm","--cached","--","deleted"])
        let full=try await collect(repo),shell=try await collect(repo,.shell),extended=try await collect(repo,.shellExtended)
        XCTAssertEqual(full.entries[root.path+"/"+path],.modified);XCTAssertEqual(full.entries[root.path+"/added"],.added);XCTAssertEqual(full.entries[root.path+"/deleted"],.deleted);XCTAssertEqual(full.entries[root.path+"/ignored"],.ignored)
        for light in [shell,extended] {XCTAssertEqual(light.entries[root.path+"/"+path],.normal);XCTAssertEqual(light.entries[root.path+"/added"],.normal);XCTAssertEqual(light.entries[root.path+"/deleted"],.untracked);XCTAssertEqual(light.entries[root.path+"/ignored"],.untracked)}
        let authoritative=try await repo.status(refreshIndex:false);XCTAssertTrue(authoritative.contains{$0.path==path&&$0.state == .modified})
    }
    func testShellNonrecursiveAndExtendedRecursiveFolderRollup() async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let folder=root.appendingPathComponent("outer/inner");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("before\n".utf8).write(to:folder.appendingPathComponent("tracked"));_ = try await repo.run(["add","--","outer"]);_ = try await repo.run(["commit","-m","nested"])
        try Data("after and longer\n".utf8).write(to:folder.appendingPathComponent("tracked"))
        let shell=try await collect(repo,.shell),extended=try await collect(repo,.shellExtended)
        XCTAssertEqual(shell.entries[folder.path],.modified);XCTAssertEqual(shell.entries[root.path+"/outer"],.normal);XCTAssertEqual(shell.entries[root.path],.normal)
        XCTAssertEqual(extended.entries[root.path+"/outer"],.modified);XCTAssertEqual(extended.entries[root.path],.modified)
    }
    func testContentThresholdIsStrictKiBAndDoesNotRefreshTheIndex() async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        for (name,size) in [("small",1023),("boundary",1024)] {try Data(repeating:65,count:size).write(to:root.appendingPathComponent(name))}
        _ = try await repo.run(["add","--","small","boundary"]);_ = try await repo.run(["commit","-m","sizes"])
        let index=root.appendingPathComponent(".git/index"),before=try Data(contentsOf:index)
        try touch(root.appendingPathComponent("small"));try touch(root.appendingPathComponent("boundary"))
        let bounded=try await collect(repo,limit:1),disabled=try await collect(repo,limit:0)
        XCTAssertEqual(bounded.entries[root.path+"/small"],.normal);XCTAssertEqual(bounded.entries[root.path+"/boundary"],.modified);XCTAssertEqual(disabled.entries[root.path+"/small"],.modified)
        XCTAssertEqual(try Data(contentsOf:index),before)
    }
    func testCleanFiltersAndLiteralSymlinkTargetsUseIndexedBlobHash() async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["config","filter.upper.clean","tr a-z A-Z"])
        try Data("filtered filter=upper\n".utf8).write(to:root.appendingPathComponent(".gitattributes"));try Data("lowercase\n".utf8).write(to:root.appendingPathComponent("filtered"))
        try FileManager.default.createSymbolicLink(atPath:root.path+"/link",withDestinationPath:"missing target")
        _ = try await repo.run(["add","--",".gitattributes","filtered","link"]);_ = try await repo.run(["commit","-m","filtered"])
        try touch(root.appendingPathComponent("filtered"))
        let result=try await collect(repo);XCTAssertEqual(result.entries[root.path+"/filtered"],.normal);XCTAssertEqual(result.entries[root.path+"/link"],.normal)
        try FileManager.default.removeItem(atPath:root.path+"/link");try FileManager.default.createSymbolicLink(atPath:root.path+"/link",withDestinationPath:"changed target")
        let changed=try await collect(repo);XCTAssertEqual(changed.entries[root.path+"/link"],.modified)
    }
    func testSkipWorktreeAndAssumeValidSuppressMissingButDoNotHideConflicts() async throws {
        let(root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("flag\n".utf8).write(to:root.appendingPathComponent("flag"));_ = try await repo.run(["add","--","flag"]);_ = try await repo.run(["commit","-m","flags"])
        _ = try await repo.run(["update-index","--skip-worktree","--",path]);_ = try await repo.run(["update-index","--assume-unchanged","--","flag"])
        try FileManager.default.removeItem(at:root.appendingPathComponent(path));try FileManager.default.removeItem(at:root.appendingPathComponent("flag"))
        let result=try await collect(repo,.shell);XCTAssertEqual(result.entries[root.path+"/"+path],.normal);XCTAssertEqual(result.entries[root.path+"/flag"],.normal)
        XCTAssertTrue(result.indexFlags[root.path+"/"+path]?.skipWorktree==true);XCTAssertTrue(result.indexFlags[root.path+"/flag"]?.assumeUnchanged==true)
        let(conflictRoot,conflictRepo,conflictPath)=try await ConflictResolutionTests().fixture();defer{try? FileManager.default.removeItem(at:conflictRoot)}
        let conflict=try await collect(conflictRepo,.shell);XCTAssertEqual(conflict.entries[conflictRoot.path+"/"+conflictPath],.conflicted);XCTAssertEqual(conflict.entries[conflictRoot.path],.conflicted)
    }
    func testEffectiveCaseSensitivityUsesIndexCapsAndExactLiteralPaths() async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["config","core.ignorecase","true"])
        let forced=try await collect(repo,caseSensitive:true),retained=try await collect(repo,caseSensitive:false)
        XCTAssertTrue(forced.caseSensitive);XCTAssertFalse(retained.caseSensitive)
        _ = try await repo.run(["config","core.ignorecase","false"])
        let sensitive=try await collect(repo,caseSensitive:false);XCTAssertTrue(sensitive.caseSensitive)
        let literal="[*]\t雪\nfile";try Data("literal".utf8).write(to:root.appendingPathComponent(literal));_ = try await repo.run(["add","--",literal])
        let result=try await collect(repo);XCTAssertEqual(result.entries[root.path+"/"+literal],.added)
        try Data("case-only".utf8).write(to:root.appendingPathComponent("CaseName"));_ = try await repo.run(["add","--","CaseName"]);_ = try await repo.run(["commit","-m","case base"])
        // APFS can retain an insensitive volume even when core.ignorecase is
        // explicitly false; a two-hop rename captures the intended index bytes.
        _ = try await repo.run(["mv","--","CaseName","case-rename-intermediate"])
        _ = try await repo.run(["mv","--","case-rename-intermediate","casename"]);_ = try await repo.run(["config","core.ignorecase","true"])
        let exact=try await collect(repo,caseSensitive:true),folded=try await collect(repo,caseSensitive:false)
        XCTAssertEqual(exact.entries[root.path+"/casename"],.added);XCTAssertEqual(folded.entries[root.path+"/casename"],.normal)
    }
    func testUnbornNoneAndCancelledCollectionPreserveWorktree() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root);_ = try await repo.run(["init"]);try Data("added".utf8).write(to:root.appendingPathComponent("new"));_ = try await repo.run(["add","--","new"])
        let full=try await collect(repo),light=try await collect(repo,.shell),none=try await collect(repo,.none)
        XCTAssertEqual(full.entries[root.path+"/new"],.added);XCTAssertEqual(light.entries[root.path+"/new"],.normal);XCTAssertEqual(none.entries,[root.path:.normal])
        let token=OperationCancellation();token.cancel();do{_ = try await repo.collectFinderOverlay(policy:.init(),cancellation:token);XCTFail("cancelled collector returned metadata")}catch{}
    }
    func testExactIndexSizeAndTimestampAreTrustedLikeSource() async throws {
        let(root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent(path);var info=stat();XCTAssertEqual(lstat(file.path,&info),0)
        var bytes=try Data(contentsOf:file);bytes[0]=bytes[0]==65 ? 66:65;try bytes.write(to:file)
        var times=[info.st_atimespec,info.st_mtimespec]
        XCTAssertEqual(times.withUnsafeMutableBufferPointer{utimensat(AT_FDCWD,file.path,$0.baseAddress,0)},0)
        let result=try await collect(repo);XCTAssertEqual(result.entries[root.path+"/"+path],.normal,"Source trusts matching size+mtime; this policy does not promise content verification in that case")
    }
    func testFilterStatRaceIsModifiedAndExternalIndexReplacementRefusesPublication() async throws {
        let(root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("race filter=race\n".utf8).write(to:root.appendingPathComponent(".gitattributes"));try Data("same\n".utf8).write(to:root.appendingPathComponent("race"))
        _ = try await repo.run(["config","filter.race.clean","cat"]);_ = try await repo.run(["add","--",".gitattributes","race"]);_ = try await repo.run(["commit","-m","race base"])
        _ = try await repo.run(["config","filter.race.clean","cat; touch race"]);try touch(root.appendingPathComponent("race"))
        let changed=try await collect(repo);XCTAssertEqual(changed.entries[root.path+"/race"],.modified)
        _ = try await repo.run(["config","filter.race.clean","cat; git update-index --assume-unchanged -- '"+path+"'"])
        try touch(root.appendingPathComponent("race"))
        do {_ = try await collect(repo);XCTFail("external index replacement published a stale collection")}catch{XCTAssertTrue(error.localizedDescription.contains("index changed"))}
    }
    func testMissingHelperAndCorruptIndexFailWithoutChangingRepository() async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let missing=GitRepository(root:root,libgit2Configuration:.init(enabled:false,mask:0,helperURL:root.appendingPathComponent("missing-helper")))
        do {_ = try await collect(missing);XCTFail("overlay reader silently selected a different engine")}catch{XCTAssertTrue(error is GitLibGit2Failure)}
        let index=root.appendingPathComponent(".git/index"),bytes=try Data(contentsOf:index);defer{try? bytes.write(to:index)}
        try Data("corrupt index".utf8).write(to:index)
        do {_ = try await collect(repo);XCTFail("corrupt index became clean badges")}catch{}
        XCTAssertEqual(try Data(contentsOf:index),Data("corrupt index".utf8))
    }
    private func frame(_ row:[String:Any]) throws -> Data {FinderStatusProtocol.prefix+(try JSONSerialization.data(withJSONObject:row)).base64EncodedData()+Data([10])}
    func testProtocolRefusesMalformedUntrustedOrIncompleteCollectionsAndHonorsLiteralBytes() throws {
        let root=URL(fileURLWithPath:"/repo"),policy=FinderStatusPolicy(),header=try frame(["kind":"header","caseSensitive":true]),end=try frame(["kind":"end","count":1])
        func row(_ path:String,_ state:Any=0)throws->Data {try frame(["kind":"entry","path":path,"state":state,"skipWorktree":false,"assumeUnchanged":false])}
        let path="a\t雪\n[*]",valid=try header+row(path)+end
        let decoded=try FinderStatusProtocol.decode(valid,root:root,policy:policy);XCTAssertEqual(decoded.entries["/repo/"+path],.normal)
        for path in ["../outside","/outside","a//b",".git/index","a/./b","",String(repeating:"x",count:1048577)] {XCTAssertThrowsError(try FinderStatusProtocol.decode(header+row(path)+end,root:root,policy:policy))}
        for state in [true,7,-1,0.5] as [Any] {XCTAssertThrowsError(try FinderStatusProtocol.decode(header+row("a",state)+end,root:root,policy:policy))}
        XCTAssertThrowsError(try FinderStatusProtocol.decode(valid.dropLast(),root:root,policy:policy));XCTAssertThrowsError(try FinderStatusProtocol.decode(header+end,root:root,policy:policy));XCTAssertThrowsError(try FinderStatusProtocol.decode(valid+end,root:root,policy:policy))
    }
    func testSharedPolicyReadFailsClosedForMalformedAuthoritativeCacheMode() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:folder)}
        let status=folder.appendingPathComponent("status.json"),settings=folder.appendingPathComponent("overlay-settings.json")
        XCTAssertEqual(try FinderStatusPolicy.read(from:status).cacheMode,.standard)
        for data in [Data("broken JSON".utf8),Data("{\"cacheMode\":999}".utf8)] {
            try data.write(to:settings);XCTAssertThrowsError(try FinderStatusPolicy.read(from:status))
        }
        var accepted=FinderOverlaySettings();accepted.cacheMode = .shellExtended;_ = try accepted.write(to:settings)
        XCTAssertEqual(try FinderStatusPolicy.read(from:status).cacheMode,.shellExtended)
    }
    func testPolicyIdentityIncludesEveryEffectiveInput() throws {
        let base=FinderStatusPolicy(),variants=[FinderStatusPolicy(cacheMode:.shell),.init(caseSensitive:false),.init(contentCheckLimitKiB:0),.init(blockStatus:true)]
        for value in variants {XCTAssertNotEqual(value.identity,base.identity);XCTAssertEqual(try JSONDecoder().decode(FinderStatusPolicy.self,from:JSONEncoder().encode(value)),value)}
    }
}
