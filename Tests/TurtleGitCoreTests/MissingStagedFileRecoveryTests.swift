import XCTest
import Darwin
@testable import TurtleGitCore

final class MissingStagedFileRecoveryTests: XCTestCase {
    private func fixture() async throws -> (URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMissing-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        do {
        let repo=GitRepository(root:root)
        _ = try await repo.run(["init"])
        _ = try await repo.run(["config","user.name","Private Recovery"])
        _ = try await repo.run(["config","user.email","recovery@example.invalid"])
        _ = try await repo.run(["config","core.precomposeunicode","false"])
        return (root,repo)
        } catch { try? FileManager.default.removeItem(at:root);throw error }
    }
    private func missing(_ repo:GitRepository) async throws -> [MissingStagedFile] {
        let status=try await repo.status(); return try await repo.missingStagedFiles(in:status)
    }
    private func add(_ path:String,_ bytes:Data,root:URL,repo:GitRepository) async throws {
        try FileManager.default.createDirectory(at:root.appendingPathComponent(path).deletingLastPathComponent(),withIntermediateDirectories:true)
        try bytes.write(to:root.appendingPathComponent(path)); _ = try await repo.run(["add","--",path])
    }
    func testUnbornLiteralAddedPathsRestoreExactBytesWithoutChangingIndex() async throws {
        let (root,repo)=try await fixture(); defer {try? FileManager.default.removeItem(at:root)}
        let paths=["a[*]\n雪.bin","b?\té.bin","c-e\u{301}.bin"]
        for (i,path) in paths.enumerated() {
            // Foundation file URLs normalize NFC names to NFD. This fixture
            // deliberately creates both literal Git spellings through POSIX so
            // a byte-preserving Git add actually indexes every requested path.
            let descriptor=open(root.path+"/"+path,O_WRONLY|O_CREAT|O_EXCL,0o600)
            guard descriptor >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
            let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
            try handle.write(contentsOf:Data([0,255,UInt8(i),13,10]));try handle.close()
            _ = try await repo.run(["add","--",path])
            try FileManager.default.removeItem(at:root.appendingPathComponent(path))
        }
        let indexedPaths=try await repo.run(["ls-files","-z"]).stdout.split(separator:0).map { Data($0) }
        XCTAssertEqual(Set(indexedPaths),Set(paths.map { Data($0.utf8) }))
        let index=try await repo.run(["ls-files","--stage","-z"]).stdout
        let candidates=try await missing(repo);XCTAssertEqual(Set(candidates.map { Data($0.path.utf8) }),Set(paths.map { Data($0.utf8) }))
        let indexBytes=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        for value in candidates {
            let result=try await repo.recoverMissingStagedFile(value,action:.restoreFromIndex)
            XCTAssertTrue(result.changed)
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(value.path)),Data([0,255,UInt8(paths.firstIndex(of:value.path)!),13,10]))
        }
        let after=try await repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertEqual(after,index);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),indexBytes);let remaining=try await missing(repo);XCTAssertTrue(remaining.isEmpty)
    }
    func testModifiedAndRenamedMissingEntriesUseIndexNotHeadAndPreserveUnrelatedChanges() async throws {
        let (root,repo)=try await fixture(); defer {try? FileManager.default.removeItem(at:root)}
        for path in ["modified","old","other"] {try await add(path,Data((path+" base\n").utf8),root:root,repo:repo)}
        _ = try await repo.commit(message:"base")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        try await add("modified",Data("staged replacement\n".utf8),root:root,repo:repo)
        _ = try await repo.run(["mv","--","old","new[*]\n雪"])
        try await add("other",Data("other staged\n".utf8),root:root,repo:repo)
        try Data("other working\n".utf8).write(to:root.appendingPathComponent("other"))
        for path in ["modified","new[*]\n雪"] {try FileManager.default.removeItem(at:root.appendingPathComponent(path))}
        let index=try await repo.run(["ls-files","--stage","-z"]).stdout
        let candidates=try await missing(repo);XCTAssertEqual(Set(candidates.map(\.path)),Set(["modified","new[*]\n雪"]))
        for candidate in candidates {_ = try await repo.recoverMissingStagedFile(candidate,action:.restoreFromIndex)}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("modified")),"staged replacement\n")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("new[*]\n雪")),"old base\n")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("other")),"other working\n")
        let after=try await repo.run(["ls-files","--stage","-z"]).stdout,afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(after,index);XCTAssertEqual(afterHead,head)
    }
    func testRemoveCachedSequentialPlansPreserveOtherStagingAndFlags() async throws {
        let (root,repo)=try await fixture(); defer {try? FileManager.default.removeItem(at:root)}
        for path in ["a","b","keep"] {try await add(path,Data(path.utf8),root:root,repo:repo)}
        _ = try await repo.commit(message:"base")
        _ = try await repo.run(["update-index","--assume-unchanged","--","keep"])
        _ = try await repo.run(["update-index","--split-index"])
        for path in ["a","b"] {try await add(path,Data("staged".utf8),root:root,repo:repo);try FileManager.default.removeItem(at:root.appendingPathComponent(path))}
        let kept=try await repo.run(["ls-files","-v","--stage","-z","--","keep"]).stdout
        let candidates=try await missing(repo);XCTAssertEqual(candidates.count,2)
        for candidate in candidates {let result=try await repo.recoverMissingStagedFile(candidate,action:.removeFromIndex);XCTAssertTrue(result.changed)}
        let after=try await repo.run(["ls-files","-v","--stage","-z","--","keep"]).stdout
        XCTAssertEqual(kept,after)
        let names=try await repo.run(["ls-files","-z"]).stdout
        XCTAssertEqual(names,Data("keep\0".utf8));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("a").path))
    }
    func testIgnoreAndOrdinaryMissingOrConflictedRowsDoNotMutate() async throws {
        let (root,repo)=try await fixture(); defer {try? FileManager.default.removeItem(at:root)}
        try await add("ordinary",Data("base".utf8),root:root,repo:repo);_ = try await repo.commit(message:"base")
        try FileManager.default.removeItem(at:root.appendingPathComponent("ordinary"))
        try await add("added",Data("a".utf8),root:root,repo:repo);try FileManager.default.removeItem(at:root.appendingPathComponent("added"))
        let before=try await repo.run(["ls-files","--stage","-z"]).stdout
        let candidates=try await missing(repo);XCTAssertEqual(candidates.map(\.path),["added"])
        let ignored=try await repo.recoverMissingStagedFile(candidates[0],action:.ignore)
        XCTAssertFalse(ignored.changed);XCTAssertEqual(ignored.output,"")
        let synthetic=[StatusEntry(path:"added",originalPath:nil,index:"U",worktree:"U"),StatusEntry(path:"ordinary",originalPath:nil,index:" ",worktree:"D")]
        let excluded=try await repo.missingStagedFiles(in:synthetic);XCTAssertTrue(excluded.isEmpty)
        let after=try await repo.run(["ls-files","--stage","-z"]).stdout;XCTAssertEqual(before,after)
    }
    func testRecreatedLeafChangedIndexAndChangedHeadRefuseWithoutOverwriting() async throws {
        let (root,repo)=try await fixture(); defer {try? FileManager.default.removeItem(at:root)}
        try await add("file",Data("base".utf8),root:root,repo:repo);_ = try await repo.commit(message:"base")
        try await add("file",Data("stage".utf8),root:root,repo:repo);try FileManager.default.removeItem(at:root.appendingPathComponent("file"))
        let captured=try await missing(repo);let plan=try XCTUnwrap(captured.first)
        try Data("recreated".utf8).write(to:root.appendingPathComponent("file"))
        for action in [MissingStagedFileAction.restoreFromIndex,.removeFromIndex] {do {_ = try await repo.recoverMissingStagedFile(plan,action:action);XCTFail("accepted recreated target")} catch {}}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file")),"recreated")
        _ = try await repo.run(["add","--","file"]);try FileManager.default.removeItem(at:root.appendingPathComponent("file"))
        do {_ = try await repo.recoverMissingStagedFile(plan,action:.restoreFromIndex);XCTFail("accepted changed index")}catch{}
        let recaptured=try await missing(repo);let fresh=try XCTUnwrap(recaptured.first)
        _ = try await repo.run(["commit","--allow-empty","-m","new head"])
        do {_ = try await repo.recoverMissingStagedFile(fresh,action:.removeFromIndex);XCTFail("accepted changed HEAD")}catch{}
    }
    func testFiltersExecutableLinksAndMissingParentDirectories() async throws {
        let (root,repo)=try await fixture(); defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["config","filter.recovery.clean","cat"])
        _ = try await repo.run(["config","filter.recovery.smudge","sed s/STAGED/SMUDGED/g"])
        try await add(".gitattributes",Data("*.filter filter=recovery\n".utf8),root:root,repo:repo)
        try await add("folder/file.filter",Data("STAGED\n".utf8),root:root,repo:repo)
        try await add("folder/second.filter",Data("STAGED second\n".utf8),root:root,repo:repo)
        try await add("exec",Data("#!/bin/sh\n".utf8),root:root,repo:repo)
        _ = try await repo.run(["update-index","--chmod=+x","--","exec"])
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("link").path,withDestinationPath:"outside-do-not-follow")
        _ = try await repo.run(["add","--","link"])
        try FileManager.default.removeItem(at:root.appendingPathComponent("folder"))
        for path in ["exec","link"] {try FileManager.default.removeItem(at:root.appendingPathComponent(path))}
        let candidates=try await missing(repo);XCTAssertEqual(candidates.count,4)
        for candidate in candidates {_ = try await repo.recoverMissingStagedFile(candidate,action:.restoreFromIndex)}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("folder/file.filter")),"SMUDGED\n")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("folder/second.filter")),"SMUDGED second\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("exec").path)[.posixPermissions] as? NSNumber)?.intValue,0o755)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:root.appendingPathComponent("link").path),"outside-do-not-follow")
    }
    func testFilterRecreatingLeafCannotBeOverwrittenAndIndexLockCanRetry() async throws {
        let (root,repo)=try await fixture(); defer {try? FileManager.default.removeItem(at:root)}
        try await add(".gitattributes",Data("file filter=collision\n".utf8),root:root,repo:repo)
        try await add("file",Data("stage".utf8),root:root,repo:repo);try FileManager.default.removeItem(at:root.appendingPathComponent("file"))
        _ = try await repo.run(["config","filter.collision.smudge","printf recreated > file; cat"])
        let captured=try await missing(repo);let plan=try XCTUnwrap(captured.first)
        do {_ = try await repo.recoverMissingStagedFile(plan,action:.restoreFromIndex);XCTFail("filter overwrote recreated leaf")}catch{}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file")),"recreated")
        try FileManager.default.removeItem(at:root.appendingPathComponent("file"))
        _ = try await repo.run(["config","--unset","filter.collision.smudge"])
        let result=try await repo.recoverMissingStagedFile(plan,action:.restoreFromIndex);XCTAssertTrue(result.changed)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file")),"stage")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".git/index.lock").path))
    }
    func testRequiredFilterFailureRetainsIndexAndMissingTargetForRetry() async throws {
        let (root,repo)=try await fixture(); defer {try? FileManager.default.removeItem(at:root)}
        try await add(".gitattributes",Data("file filter=reject\n".utf8),root:root,repo:repo)
        try await add("file",Data("staged\n".utf8),root:root,repo:repo)
        try FileManager.default.removeItem(at:root.appendingPathComponent("file"))
        _ = try await repo.run(["config","filter.reject.required","true"])
        _ = try await repo.run(["config","filter.reject.smudge","exit 1"])
        let captured=try await missing(repo),plan=try XCTUnwrap(captured.first)
        let before=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        do {_ = try await repo.recoverMissingStagedFile(plan,action:.restoreFromIndex);XCTFail("required filter failure ignored")}catch{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("file").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".git/index.lock").path))
        _ = try await repo.run(["config","filter.reject.smudge","cat"])
        _ = try await repo.recoverMissingStagedFile(plan,action:.restoreFromIndex)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file")),"staged\n")
    }
    func testLinkedWorktreeUsesItsOwnIndexAndLeavesMainWorktreeUntouched() async throws {
        let (root,repo)=try await fixture(); defer {try? FileManager.default.removeItem(at:root)}
        try await add("file",Data("base\n".utf8),root:root,repo:repo);_ = try await repo.commit(message:"base")
        let linked=root.deletingLastPathComponent().appendingPathComponent("TurtleGitLinked-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:linked)}
        _ = try await repo.run(["worktree","add","-b","private-recovery",linked.path])
        let other=GitRepository(root:linked)
        try await add("file",Data("linked staged\n".utf8),root:linked,repo:other)
        try FileManager.default.removeItem(at:linked.appendingPathComponent("file"))
        let candidates=try await missing(other),plan=try XCTUnwrap(candidates.first)
        _ = try await other.recoverMissingStagedFile(plan,action:.restoreFromIndex)
        XCTAssertEqual(try String(contentsOf:linked.appendingPathComponent("file")),"linked staged\n")
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file")),"base\n")
        let main=try await repo.run(["show",":file"]).stdout,child=try await other.run(["show",":file"]).stdout
        XCTAssertEqual(main,Data("base\n".utf8));XCTAssertEqual(child,Data("linked staged\n".utf8))
    }
    func testRepositoryCapturedBeforeDirectoryCreationUsesRealOwnerIdentity() async throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMissingPrecreated-"+UUID().uuidString).resolvingSymlinksInPath().path
        let root=URL(fileURLWithPath:path,isDirectory:false)
        let repo=GitRepository(root:root)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["init"])
        try await add("file",Data("staged\n".utf8),root:root,repo:repo)
        try FileManager.default.removeItem(at:root.appendingPathComponent("file"))
        let candidates=try await missing(repo),plan=try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.map(\.path),["file"])
        _ = try await repo.recoverMissingStagedFile(plan,action:.restoreFromIndex)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file")),"staged\n")
        try FileManager.default.removeItem(at:root.appendingPathComponent("file"))
        _ = try await repo.recoverMissingStagedFile(plan,action:.removeFromIndex)
        let after=try await repo.run(["ls-files","-z"]).stdout;XCTAssertTrue(after.isEmpty)
        // A different nested owner remains forbidden even though it is inside
        // the same outer worktree and URL metadata no longer participates.
        try await add("nested/file",Data("nested staged\n".utf8),root:root,repo:repo)
        try FileManager.default.removeItem(at:root.appendingPathComponent("nested/file"))
        _ = try await repo.run(["init","nested"])
        do { _ = try await missing(repo);XCTFail("accepted nested repository owner") }
        catch MissingStagedFileRecoveryFailure.location { }
    }
    func testCancellationAndUnsafeParentReplacementDoNotPublish() async throws {
        let (root,repo)=try await fixture(); defer {try? FileManager.default.removeItem(at:root)}
        try await add("folder/file",Data("stage".utf8),root:root,repo:repo);try FileManager.default.removeItem(at:root.appendingPathComponent("folder/file"))
        let captured=try await missing(repo);let plan=try XCTUnwrap(captured.first),token=OperationCancellation();token.cancel()
        do {_ = try await repo.recoverMissingStagedFile(plan,action:.restoreFromIndex,cancellation:token);XCTFail("accepted cancellation")}catch{}
        let outside=root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:outside)}
        try FileManager.default.removeItem(at:root.appendingPathComponent("folder"));try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("folder"),withDestinationURL:outside)
        do {_ = try await repo.recoverMissingStagedFile(plan,action:.restoreFromIndex);XCTFail("accepted escaping parent")}catch{}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:outside.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".git/index.lock").path))
    }
}
