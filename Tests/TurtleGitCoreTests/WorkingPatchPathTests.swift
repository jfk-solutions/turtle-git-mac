// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class WorkingPatchPathTests:XCTestCase {
    private let old="old-café/--file[*]\n.txt",new="new-cafe\u{301}/--target? &.txt"
    private func fixture(binary:Bool=false) async throws ->(URL,GitRepository,Data,Data,Data) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitPatchPaths-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_TEST_GIT"] ?? "/usr/bin/git"))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Patch path QA"),("user.email","path@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
        let base=binary ? Data([0])+Data(repeating:65,count:8192):Data((0..<12).map {"base line \($0)\n"}.joined().utf8)
        var changed=base
        if binary {changed[changed.count-1]=66} else {changed=Data(String(decoding:base,as:UTF8.self).replacingOccurrences(of:"base line 4",with:"patched line 4").utf8)}
        let file=FileTransferPaths.fileURL(root.path+"/"+old)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try base.write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        let before=try await repo.run(["hash-object","-w","--stdin"],input:base).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["update-index","-z","--index-info"],input:Data("100755 \(before)\t\(old)\0".utf8))
        _=try await repo.commit(message:"source")
        let after=try await repo.run(["hash-object","-w","--stdin"],input:changed).text.trimmingCharacters(in:.newlines)
        let entries="0 "+String(repeating:"0",count:40)+"\t"+old+"\0"+"100755 "+after+"\t"+new+"\0"
        _=try await repo.run(["update-index","-z","--index-info"],input:Data(entries.utf8))
        let patch=try await repo.run(["diff","--cached","--binary","--full-index","--find-renames=50%","HEAD","--"]).stdout
        _=try await repo.run(["read-tree","HEAD"])
        return (root,repo,patch,base,changed)
    }
    func testOwnedRenameDestinationCopyRetainsSourceGuardsAndLaterPatchSave() async throws {
        let (root,repo,patch,_,_)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let review=try await repo.reviewWorkingTreePatch(patch),comparison=try await repo.compareWorkingTreePatchFile(review,fileID:0)
        let output=FileTransferPaths.fileURL(root.path+"/"+new),copy=Data("owned copy\n".utf8)
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        try MergePaneSaveAs.write(copy,to:output)
        let updated=comparison.recordingOwnedWrite(try SavedMergePane(url:output,writtenBytes:copy,encoding:.utf8))
        XCTAssertEqual(updated.document.base.bytes,comparison.document.base.bytes)
        XCTAssertEqual(updated.document.destination.bytes,comparison.document.destination.bytes)
        _=try await repo.saveWorkingTreePatchFile(updated,text:"later resolved\n",autoAddNewFiles:false)
        XCTAssertEqual(try Data(contentsOf:output),Data("later resolved\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:FileTransferPaths.fileURL(root.path+"/"+old).path))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testOwnedCopyRetainsExternalGuardsAndOriginalNewFileAddPolicy() async throws {
        let (root,repo,patch,_,_)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let review=try await repo.reviewWorkingTreePatch(patch),comparison=try await repo.compareWorkingTreePatchFile(review,fileID:0)
        let output=FileTransferPaths.fileURL(root.path+"/"+new),source=FileTransferPaths.fileURL(root.path+"/"+old),copy=Data("owned copy\n".utf8),original=try Data(contentsOf:source)
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        try MergePaneSaveAs.write(copy,to:output)
        let updated=comparison.recordingOwnedWrite(try SavedMergePane(url:output,writtenBytes:copy,encoding:.utf8))
        try Data("external source\n".utf8).write(to:source)
        do {_=try await repo.saveWorkingTreePatchFile(updated,text:"resolved\n");XCTFail("Lost untouched source guard")} catch FileComparisonEditFailure.changed {}
        try original.write(to:source);try Data("external destination\n".utf8).write(to:output)
        do {_=try await repo.saveWorkingTreePatchFile(updated,text:"resolved\n");XCTFail("Lost adopted destination guard")} catch FileComparisonEditFailure.changed {}
        try copy.write(to:output)
        let saved=try await repo.saveWorkingTreePatchFile(updated,text:"resolved\n")
        XCTAssertNil(saved.addError)
        let staged=try await repo.run(["show",":"+new]).stdout
        XCTAssertEqual(staged,Data("resolved\n".utf8))
    }
    func testRenamePreviewEditedSaveAndReversePreserveExactNamesAndIndex() async throws {
        let (root,repo,patch,base,changed)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let review=try await repo.reviewWorkingTreePatch(patch)
        XCTAssertEqual(review.files.count,1);XCTAssertEqual(review.files.first?.pathBytes,Data(new.utf8));XCTAssertTrue(review.canApply)
        let comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id)
        XCTAssertEqual(Data(comparison.document.base.path.utf8),Data(old.utf8));XCTAssertEqual(Data(comparison.document.destination.path.utf8),Data(new.utf8))
        XCTAssertEqual(comparison.document.base.bytes,base);XCTAssertEqual(comparison.document.destination.bytes,changed)
        let edited="edited café\r\nno final newline",saved=try await repo.saveWorkingTreePatchFile(comparison,text:edited,autoAddNewFiles:false)
        XCTAssertEqual(Data(saved.document.destination.path.utf8),Data(new.utf8))
        let oldURL=FileTransferPaths.fileURL(root.path+"/"+old),newURL=FileTransferPaths.fileURL(root.path+"/"+new)
        XCTAssertFalse(FileManager.default.fileExists(atPath:oldURL.path));XCTAssertEqual(try Data(contentsOf:newURL),Data(edited.utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:newURL.path)[.posixPermissions] as? NSNumber)?.intValue,0o755)
        // Reverse uses the opposite path without replacing it by a normalized URL spelling.
        try changed.write(to:newURL)
        let reverse=try await repo.reviewWorkingTreePatch(patch,reversed:true)
        let reversed=try await repo.compareWorkingTreePatchFile(reverse,fileID:reverse.files[0].id)
        XCTAssertEqual(Data(reversed.document.base.path.utf8),Data(new.utf8));XCTAssertEqual(Data(reversed.document.destination.path.utf8),Data(old.utf8))
        _=try await repo.saveWorkingTreePatchFile(reversed,text:String(decoding:base,as:UTF8.self),autoAddNewFiles:false)
        XCTAssertEqual(try Data(contentsOf:oldURL),base);XCTAssertFalse(FileManager.default.fileExists(atPath:newURL.path))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(finalHead,head)
    }
    func testRecordedBaseRenameRecoveryAndStaleSourceRefusal() async throws {
        let (root,repo,patch,base,changed)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let oldURL=FileTransferPaths.fileURL(root.path+"/"+old),local=Data("local conflict\n".utf8)
        try local.write(to:oldURL)
        let review=try await repo.reviewWorkingTreePatch(patch),comparison=try await repo.compareWorkingTreePatchFile(review,fileID:0)
        XCTAssertFalse(review.canApply);XCTAssertTrue(comparison.requiresMerge)
        XCTAssertEqual(comparison.recoveryBase?.bytes,base);XCTAssertEqual(comparison.document.base.bytes,local);XCTAssertEqual(comparison.document.destination.bytes,changed)
        XCTAssertEqual(comparison.recoveryBase.map {Data($0.path.utf8)},Data(old.utf8))
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),external=Data("external after preview\n".utf8)
        try external.write(to:oldURL)
        do {_=try await repo.saveWorkingTreePatchFile(comparison,text:"resolved\n",autoAddNewFiles:false);XCTFail("Stale rename source accepted")} catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try Data(contentsOf:oldURL),external);XCTAssertFalse(FileManager.default.fileExists(atPath:FileTransferPaths.fileURL(root.path+"/"+new).path))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testBinaryRenameCurrentAndPatchedChoicesKeepExactPathsAndModes() async throws {
        let (root,repo,patch,base,changed)=try await fixture(binary:true);defer {try? FileManager.default.removeItem(at:root)}
        let oldURL=FileTransferPaths.fileURL(root.path+"/"+old),newURL=FileTransferPaths.fileURL(root.path+"/"+new),local=base+Data([67])
        try local.write(to:oldURL)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        var review=try await repo.reviewWorkingTreePatch(patch),comparison=try await repo.compareWorkingTreePatchFile(review,fileID:0)
        XCTAssertEqual(review.files.count,1);XCTAssertEqual(comparison.recoveryKind,.binary)
        _=try await repo.resolveWorkingTreePatchFile(comparison,choice:.current,autoAddNewFiles:false)
        XCTAssertEqual(try Data(contentsOf:oldURL),local);XCTAssertFalse(FileManager.default.fileExists(atPath:newURL.path))
        review=try await repo.reviewWorkingTreePatch(patch);comparison=try await repo.compareWorkingTreePatchFile(review,fileID:0)
        let saved=try await repo.resolveWorkingTreePatchFile(comparison,choice:.patched,autoAddNewFiles:false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:oldURL.path));XCTAssertEqual(try Data(contentsOf:newURL),changed)
        XCTAssertEqual(Data(saved.document.destination.path.utf8),Data(new.utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:newURL.path)[.posixPermissions] as? NSNumber)?.intValue,0o755)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testCanonicalPeerPatchReviewSelectionRetainsExactGitRecords() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root),a="café[*]\n.txt",b="cafe\u{301}[*]\n.txt"
        _=try await repo.run(["init","-b","main"])
        _=try await repo.run(["config","core.precomposeunicode","true"])
        let blob=try await repo.run(["hash-object","-w","--stdin"],input:Data("created\n".utf8)).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["update-index","-z","--index-info"],input:Data("100644 \(blob)\t\(a)\0".utf8)+Data("100644 \(blob)\t\(b)\0".utf8))
        let patch=try await repo.run(["diff","--cached","--binary","--full-index","--"]).stdout
        _=try await repo.run(["read-tree","--empty"])
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),configuration=try Data(contentsOf:root.appendingPathComponent(".git/config")),review=try await repo.reviewWorkingTreePatch(patch)
        XCTAssertEqual(Set(review.files.map(\.pathBytes)),Set([Data(a.utf8),Data(b.utf8)]))
        for path in [a,b] {
            let file=try XCTUnwrap(review.files.first {$0.pathBytes==Data(path.utf8)}),selected=try await repo.reviewWorkingTreePatchFiles(review,fileIDs:[file.id])
            XCTAssertEqual(selected.files.count,1);XCTAssertEqual(selected.files.first?.pathBytes,Data(path.utf8))
        }
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertFalse(FileManager.default.fileExists(atPath:FileTransferPaths.fileURL(root.path+"/"+a).path))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/config")),configuration)
    }
}
