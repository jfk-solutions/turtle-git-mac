import XCTest
@testable import TurtleGitCore

private final class PatchProgressReceipts:@unchecked Sendable {
    private let lock=NSLock();private var values:[WorkingTreePatchProgress]=[]
    func append(_ value:WorkingTreePatchProgress){lock.lock();values.append(value);lock.unlock()}
    var snapshot:[WorkingTreePatchProgress]{lock.lock();defer{lock.unlock()};return values}
}
final class WorkingPatchSavePolicyTests:XCTestCase {
    private func fixture()async throws->(URL,GitRepository,Data) {
        let(root,repo,_)=try await GitPatchTests().fixture()
        let file=root.appendingPathComponent("policy.txt")
        try Data("before\n".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        try await repo.stage(["policy.txt"]);_=try await repo.commit(message:"Patch save policy")
        try Data("proposed\n".utf8).write(to:file)
        let patch=try await repo.run(["diff","--binary","--full-index","--","policy.txt"]).stdout
        try Data("before\n".utf8).write(to:file)
        return(root,repo,patch)
    }
    private func addition(_ path:String,_ content:String)->Data {
        Data("diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1 @@\n+\(content)\n".utf8)
    }
    func testAutomaticNewFileAddUsesCapturedPolicyAndKeepsHead()async throws {
        for enabled in [false,true] {
            let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            let bytes=addition("new.txt","created"),review=try await repo.reviewWorkingTreePatch(bytes)
            let result=try await repo.applyWorkingTreePatchBatch(review,fileIDs:Set(review.files.map(\.id)),autoAddNewFiles:enabled)
            XCTAssertEqual(result.files.map(\.success),[true]);XCTAssertNil(result.files[0].addError)
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("new.txt")),Data("created\n".utf8))
            let staged=try await repo.run(["diff","--cached","--name-only","-z"]).stdout
            XCTAssertEqual(staged,enabled ? Data("new.txt\0".utf8):Data())
            if !enabled {XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)}
            let currentHead=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(currentHead,head)
            XCTAssertEqual(review.document.bytes,bytes)
        }
    }
    func testAddFailureIsSeparateFromSuccessfulPatchAndPlainDirectoryNeverAdds()async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let bytes=addition("new.txt","created"),review=try await repo.reviewWorkingTreePatch(bytes)
        let lock=root.appendingPathComponent(".git/index.lock");try Data("private lock\n".utf8).write(to:lock)
        let result=try await repo.applyWorkingTreePatchBatch(review,fileIDs:Set(review.files.map(\.id)),autoAddNewFiles:true)
        XCTAssertEqual(result.files.map(\.success),[true]);XCTAssertNotNil(result.files[0].addError)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("new.txt")),"created\n")
        XCTAssertEqual(try String(contentsOf:lock),"private lock\n");try FileManager.default.removeItem(at:lock)
        let plain=root.appendingPathComponent("plain");try FileManager.default.createDirectory(at:plain,withIntermediateDirectories:true)
        let outside=GitRepository(root:plain),plainReview=try await outside.reviewWorkingTreePatch(bytes,directoryMode:true,isGitWorkingTree:false)
        let applied=try await outside.applyWorkingTreePatchBatch(plainReview,fileIDs:Set(plainReview.files.map(\.id)),autoAddNewFiles:true)
        XCTAssertEqual(applied.files.map(\.success),[true]);XCTAssertNil(applied.files[0].addError)
        XCTAssertFalse(FileManager.default.fileExists(atPath:plain.appendingPathComponent(".git").path))
    }
    func testExplicitSaveBackupRetainsOriginalExecutableBytesAndIndex()async throws {
        let(root,repo,patch)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let review=try await repo.reviewWorkingTreePatch(patch),comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let saved=try await repo.saveWorkingTreePatchFile(comparison,text:"edited\n",autoAddNewFiles:false,options:.init(backupOriginal:true))
        XCTAssertEqual(saved.document.destination.bytes,Data("edited\n".utf8));XCTAssertNil(saved.addError)
        let backup=root.appendingPathComponent("policy.txt.bak")
        XCTAssertEqual(try Data(contentsOf:backup),Data("before\n".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:backup.path)[.posixPermissions] as? NSNumber)?.intValue,0o755)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testExplicitEmptyKeepDeleteAndAutomaticPatchSaveAreDifferent()async throws {
        for mode in 0..<3 {
            let(root,repo,patch)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            let review=try await repo.reviewWorkingTreePatch(patch),comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id)
            let options:MergeFileSaveOptions?=mode==2 ? nil:.init(backupOriginal:true,emptyResult:mode==0 ? .keep:.delete)
            let saved=try await repo.saveWorkingTreePatchFile(comparison,text:"",autoAddNewFiles:false,options:options)
            let file=root.appendingPathComponent("policy.txt"),backup=root.appendingPathComponent("policy.txt.bak")
            XCTAssertEqual(saved.document.destination.isDeleted,mode != 0)
            if mode==0 {XCTAssertEqual(try Data(contentsOf:file),Data());XCTAssertNotNil(saved.document.destination.mode)}
            else {XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))}
            if mode<2 {XCTAssertEqual(try Data(contentsOf:backup),Data("before\n".utf8))}
            else {XCTAssertFalse(FileManager.default.fileExists(atPath:backup.path))}
        }
    }
    func testBackupCollisionAndStaleInputsRefuseBeforeMutation()async throws {
        for kind in ["directory","symlink","stale"] {
            let(root,repo,patch)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            let review=try await repo.reviewWorkingTreePatch(patch),comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id)
            let file=root.appendingPathComponent("policy.txt"),backup=root.appendingPathComponent("policy.txt.bak")
            if kind=="directory" {try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true)}
            if kind=="symlink" {try FileManager.default.createSymbolicLink(atPath:backup.path,withDestinationPath:"policy.txt")}
            if kind=="stale" {try Data("external\n".utf8).write(to:file)}
            do{_=try await repo.saveWorkingTreePatchFile(comparison,text:"edited\n",autoAddNewFiles:false,options:.init(backupOriginal:true));XCTFail("Unsafe/stale backup saved: "+kind)}
            catch {if kind=="stale" {guard case FileComparisonEditFailure.changed=error else{throw error}}else{guard case MergeFileSaveFailure.backupTarget=error else{throw error}}}
            XCTAssertEqual(try String(contentsOf:file),kind=="stale" ? "external\n":"before\n")
            if kind=="stale" {XCTAssertFalse(FileManager.default.fileExists(atPath:backup.path))}
        }
    }
    func testProgressIsBeforeEachRealPathAndCancellationStopsBeforeMutation()async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        var patch=addition("a.txt","first");patch.append(addition("z.txt","last"))
        let review=try await repo.reviewWorkingTreePatch(patch),receipts=PatchProgressReceipts(),token=OperationCancellation()
        let canceled=try await repo.applyWorkingTreePatchBatch(review,fileIDs:Set(review.files.map(\.id)),autoAddNewFiles:true,cancellation:token,onProgress:{value in receipts.append(value);token.cancel()})
        XCTAssertTrue(canceled.cancelled);XCTAssertTrue(canceled.files.isEmpty)
        XCTAssertEqual(receipts.snapshot.map(\.completedIndex),[0]);XCTAssertEqual(receipts.snapshot.map(\.total),[2]);XCTAssertEqual(receipts.snapshot.map(\.pathBytes),[Data("a.txt".utf8)])
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("a.txt").path));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("z.txt").path))
        let complete=PatchProgressReceipts()
        let result=try await repo.applyWorkingTreePatchBatch(review,fileIDs:Set(review.files.map(\.id)),onProgress:{complete.append($0)})
        XCTAssertEqual(result.files.map(\.success),[true,true]);XCTAssertEqual(complete.snapshot.map(\.completedIndex),[0,1]);XCTAssertEqual(complete.snapshot.map(\.total),[2,2])
    }
    func testAutomaticCleanPatchDeletesZeroRecordsButRetainsBlankLine()async throws {
        for content in [Data(),Data([0xef,0xbb,0xbf]),Data("\n".utf8)] {
            let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
            let file=root.appendingPathComponent("policy.txt");try content.write(to:file)
            let patch=try await repo.run(["diff","--binary","--full-index","--","policy.txt"]).stdout
            try Data("before\n".utf8).write(to:file)
            let review=try await repo.reviewWorkingTreePatch(patch),result=try await repo.applyWorkingTreePatchBatch(review,fileIDs:Set(review.files.map(\.id)))
            XCTAssertEqual(result.files.map(\.success),[true])
            if content==Data("\n".utf8) {XCTAssertEqual(try Data(contentsOf:file),content)}else{XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))}
            XCTAssertFalse(FileManager.default.fileExists(atPath:file.path+".bak"))
        }
    }
}

extension WorkingPatchSavePolicyTests {
    func testRecordedBaseCleanRenameMergeUsesAutoAddWithoutBackup()async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let old=root.appendingPathComponent("old.txt"),new=root.appendingPathComponent("new.txt")
        let lines=(1...20).map{"line \($0)"},base=lines.joined(separator:"\n")+"\n"
        try Data(base.utf8).write(to:old);try await repo.stage(["old.txt"]);_=try await repo.commit(message:"Recorded rename base")
        _=try await repo.run(["mv","--","old.txt","new.txt"])
        var proposed=lines;proposed[3]="patched 4";try Data((proposed.joined(separator:"\n")+"\n").utf8).write(to:new)
        let patch=try await repo.run(["diff","HEAD","--binary","--full-index","--find-renames","--"]).stdout
        _=try await repo.run(["reset","--hard","HEAD"])
        var current=lines;current[5]="local 6";try Data((current.joined(separator:"\n")+"\n").utf8).write(to:old)
        let review=try await repo.reviewWorkingTreePatch(patch);XCTAssertFalse(review.canApply)
        let repositoryRoot=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine=SubversionMergeConfiguration(executable:repositoryRoot.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"),runtimeRoot:repositoryRoot.appendingPathComponent("build/git-runtime/Git"))
        let result=try await repo.applyWorkingTreePatchBatch(review,fileIDs:Set(review.files.map(\.id)),mergeConfiguration:engine,autoAddNewFiles:true)
        XCTAssertEqual(result.files.map(\.success),[true]);XCTAssertNil(result.files[0].addError)
        var expected=proposed;expected[5]="local 6"
        XCTAssertEqual(try String(contentsOf:new),expected.joined(separator:"\n")+"\n")
        let staged=try await repo.run(["show",":new.txt"]).stdout;XCTAssertEqual(staged,Data((expected.joined(separator:"\n")+"\n").utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:old.path));XCTAssertFalse(FileManager.default.fileExists(atPath:new.path+".bak"))
    }
}

extension WorkingPatchSavePolicyTests {
    func testMetadataOnlyEmptyFileIsNotImplicitlyDeleted()async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("empty.txt");try Data().write(to:file)
        try await repo.stage(["empty.txt"]);_=try await repo.commit(message:"Existing empty metadata target")
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        let patch=try await repo.run(["diff","--binary","--","empty.txt"]).stdout
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:file.path)
        let review=try await repo.reviewWorkingTreePatch(patch),result=try await repo.applyWorkingTreePatchBatch(review,fileIDs:Set(review.files.map(\.id)))
        XCTAssertEqual(result.files.map(\.success),[true]);XCTAssertEqual(try Data(contentsOf:file),Data())
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o755)
    }
    func testNonemptyExplicitDeletionRefusesWithoutBackupOrMutation()async throws {
        let(root,repo,patch)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let review=try await repo.reviewWorkingTreePatch(patch),comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id)
        do{_=try await repo.saveWorkingTreePatchFile(comparison,text:"edited\n",options:.init(backupOriginal:true,emptyResult:.delete));XCTFail("Nonempty deletion accepted")}
        catch MergeFileSaveFailure.nonemptyDeletion {}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("policy.txt")),"before\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("policy.txt.bak").path))
    }
    func testCleanupFailureStillReportsSuccessfulActualPatch()async throws {
        let(root,repo,_)=try await fixture()
        defer{try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path);try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("policy.txt");try Data().write(to:file)
        let patch=try await repo.run(["diff","--binary","--full-index","--","policy.txt"]).stdout
        try Data("before\n".utf8).write(to:file)
        let wrapper=root.appendingPathComponent("private-git"),actual=repo.executable.path
        func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        apply=false
        inspect=false
        for value in "$@"; do
          [ "$value" = apply ] && apply=true
          case "$value" in --check|--stat|--summary|--numstat) inspect=true;; esac
        done
        \(quote(actual)) "$@"
        status=$?
        if [ "$status" = 0 ] && [ "$apply" = true ] && [ "$inspect" = false ]; then
          /bin/chmod 0555 \(quote(root.path))
        fi
        exit "$status"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let guarded=GitRepository(root:root,executable:wrapper,libgit2Configuration:.init(enabled:false))
        let review=try await guarded.reviewWorkingTreePatch(patch),result=try await guarded.applyWorkingTreePatchBatch(review,fileIDs:Set(review.files.map(\.id)))
        XCTAssertEqual(result.files.map(\.success),[true]);XCTAssertNotNil(result.files[0].postApplyError);XCTAssertNil(result.files[0].addError)
        XCTAssertEqual(try Data(contentsOf:file),Data(),"Git's actual empty mutation was lost")
        XCTAssertTrue(result.files[0].output.contains("Patch applied; empty-result cleanup did not finish"))
    }
}
