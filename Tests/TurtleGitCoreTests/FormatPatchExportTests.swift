import XCTest
import Darwin
@testable import TurtleGitCore

final class FormatPatchExportTests:XCTestCase {
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func fixture()async throws->(URL,GitRepository,String) {
        let(root,original,path)=try await GitPatchTests().fixture()
        let repo=GitRepository(root:root,executable:URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? original.executable.path))
        let base=try await repo.rebaseCommit("HEAD").hash
        for number in 1...3 {try Data("patch \(number)\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_=try await repo.run(["commit","-m","Subject Café 🐢 \(number)"])}
        return(root,repo,base)
    }
    func testVerifiedActualFilesPreserveUnicodeAndNewlineDirectoryWithBoundedDiagnostics()async throws {
        let(root,repo,base)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let folder=FileTransferPaths.fileURL(root.path+"/mail Café\nCafe\u{301} 🐢")
        let beforeHead=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let capture=LimitedOutput()
        let exported=try await repo.formatPatchFiles(selection:.range(from:base,to:"HEAD"),to:folder,onOutput:{capture.append($0.data)})
        XCTAssertEqual(exported.result.exitCode,0);XCTAssertEqual(exported.files.count,3);XCTAssertLessThan(capture.bytes.count,exported.result.stdout.count)
        let actual=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)
        XCTAssertEqual(Set(exported.files.map{Data($0.lastPathComponent.utf8)}),Set(actual.map{Data($0.lastPathComponent.utf8)}))
        for file in exported.files {let text=try String(contentsOf:file,encoding:.utf8);XCTAssertTrue(text.contains("Subject: [PATCH"));XCTAssertTrue(text.contains("diff --git \"a/file") && text.contains(" \"b/file"),"Direct source route preserves prefixes on Git's quoted Unicode/newline path")}
        let empty=try await repo.formatPatchFiles(selection:.range(from:"HEAD",to:"HEAD"),to:folder)
        XCTAssertTrue(empty.files.isEmpty);XCTAssertTrue(empty.result.stdout.isEmpty,"Preexisting files must never become a new export receipt")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(afterHead,beforeHead);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testPrecomposingGitDirectoryOutputRequiresSameApprovedDirectoryAndKeepsLiteralLeaf()async throws {
        let(original,repository,base)=try await fixture()
        let root=FileTransferPaths.fileURL(original.deletingLastPathComponent().path+"/export-root-Cafe\u{301}-"+UUID().uuidString)
        do {try FileManager.default.moveItem(at:original,to:root)}catch {try? FileManager.default.removeItem(at:original);throw error}
        defer{try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root,executable:repository.executable)
        _=try await repo.run(["config","core.precomposeunicode","true"])
        let folder=FileTransferPaths.fileURL(root.path+"/handoff Cafe\u{301}\nmail")
        let commands=LimitedOutput()
        let result=try await repo.formatPatchFiles(selection:.range(from:base,to:"HEAD"),to:folder,onCommand:{commands.command($0)})
        XCTAssertEqual(result.files.count,3)
        let invocation=try XCTUnwrap(commands.invocation),outputIndex=try XCTUnwrap(invocation.arguments.firstIndex(of:"-o"))
        let argument=invocation.arguments[outputIndex+1],composed=argument.precomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Data(argument.utf8),Data(composed.utf8),"Actual command must retain the decomposed directory argument")
        XCTAssertTrue(result.result.stdout.starts(with:Data((composed+"/").utf8)),"Git precomposeunicode must exercise a composed stdout directory")
        var actual=stat(),canonical=stat()
        XCTAssertEqual(lstat(argument,&actual),0);XCTAssertEqual(lstat(composed,&canonical),0)
        XCTAssertEqual(actual.st_dev,canonical.st_dev);XCTAssertEqual(actual.st_ino,canonical.st_ino)
        // The directory spelling may be canonicalized; arbitrary filename
        // identities are never normalized along with that approved prefix.
        let leaf="0004-literal-Cafe\u{301}.patch",file=FileTransferPaths.fileURL(argument+"/"+leaf)
        try Data("literal patch".utf8).write(to:file)
        let accepted=try FormatPatchExport.exportedFiles(stdout:Data((composed+"/"+leaf+"\n").utf8),in:folder)
        XCTAssertEqual(accepted.map{Data($0.lastPathComponent.utf8)},[Data(leaf.utf8)])
        let unrelated=root.appendingPathComponent("other-directory",isDirectory:true)
        try FileManager.default.createDirectory(at:unrelated,withIntermediateDirectories:true)
        do {_=try FormatPatchExport.exportedFiles(stdout:Data((unrelated.path+"/"+leaf+"\n").utf8),in:folder);XCTFail("Different directory accepted")}catch FormatPatchFailure.output {}
        let symlink=FileTransferPaths.fileURL(argument+"/0005-link.patch")
        try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:file)
        do {_=try FormatPatchExport.exportedFiles(stdout:Data((composed+"/0005-link.patch\n").utf8),in:folder);XCTFail("Symlink leaf accepted")}catch FormatPatchFailure.output {}
    }
    private final class LimitedOutput:@unchecked Sendable {
        private let lock=NSLock();private var storage=Data(),capturedCommand:GitCommandInvocation?
        func append(_ bytes:Data){lock.lock();defer{lock.unlock()};storage.append(bytes.prefix(max(0,8-storage.count)))}
        var bytes:Data {lock.lock();defer{lock.unlock()};return storage}
        func command(_ invocation:GitCommandInvocation){lock.lock();capturedCommand=invocation;lock.unlock()}
        var invocation:GitCommandInvocation? {lock.lock();defer{lock.unlock()};return capturedCommand}
    }
    func testStrictFileListRejectsMalformedOrUnverifiablePathsWithoutAdoptingExistingFiles()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("patch-list-"+UUID().uuidString,isDirectory:true);defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let folder=root.resolvingSymlinksInPath(),name="0001-Cafe\u{301}-🐢.patch",file=FileTransferPaths.fileURL(folder.path+"/"+name)
        try Data("patch".utf8).write(to:file)
        let exact=Data((folder.path+"/"+name+"\n").utf8)
        let accepted=try FormatPatchExport.exportedFiles(stdout:exact,in:folder)
        XCTAssertEqual(accepted.map{Data($0.lastPathComponent.utf8)},[Data(name.utf8)])
        XCTAssertTrue(try FormatPatchExport.exportedFiles(stdout:Data(),in:folder).isEmpty)
        let prefix=Data((folder.path+"/").utf8)
        for bad in [Data(exact.dropLast()),exact+exact,Data((folder.path+"/missing.patch\n").utf8),Data((folder.path+"/../outside.patch\n").utf8),Data("other output\n".utf8),prefix+Data([255,10]),prefix+Data([0,10])] {
            do {_=try FormatPatchExport.exportedFiles(stdout:bad,in:folder);XCTFail("Unverifiable output accepted")}catch FormatPatchFailure.output {}
        }
        XCTAssertEqual(try Data(contentsOf:file),Data("patch".utf8))
    }
    func testBothRangeEndpointsUseCapturedSoleMergeFetchHead()async throws {
        let(root,repo,base)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let head=try await repo.rebaseCommit("HEAD").hash,fetch=root.appendingPathComponent(".git/FETCH_HEAD")
        try Data((head+"\tnot-for-merge\tignored first\n"+base+"\t\tselected base\n").utf8).write(to:fetch)
        let from=try await repo.formatPatchFiles(selection:.range(from:"FETCH_HEAD",to:"HEAD"),to:root.appendingPathComponent("from"));XCTAssertEqual(from.files.count,3)
        try Data((base+"\tnot-for-merge\tignored first\n"+head+"\t\tselected head\n").utf8).write(to:fetch)
        let to=try await repo.formatPatchFiles(selection:.range(from:base,to:"FETCH_HEAD"),to:root.appendingPathComponent("to"));XCTAssertEqual(to.files.count,3)
        let same=try await repo.formatPatchFiles(selection:.range(from:"FETCH_HEAD",to:"FETCH_HEAD"),to:root.appendingPathComponent("same"));XCTAssertTrue(same.files.isEmpty)
        try Data((base+"\t\tone\n"+head+"\t\ttwo\n").utf8).write(to:fetch)
        for selection in [FormatPatchSelection.range(from:"FETCH_HEAD",to:"HEAD"),.range(from:base,to:"FETCH_HEAD")] {
            do {_=try await repo.formatPatchFiles(selection:selection,to:root.appendingPathComponent("invalid"));XCTFail("Ambiguous endpoint accepted")}catch FormatPatchFailure.selection {}
        }
    }
    func testFailedAndCancelledActualCommandsNeverPublishVerifiedExportsAndKeepPartialFiles()async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent(".git/export-helper"),pidFile=root.appendingPathComponent(".git/export-pid")
        let script="""
        #!/bin/sh
        if [ "${4-}" = format-patch ]; then
          /bin/mkdir -p "$6"
          printf partial > "$6/0001-partial.patch"
          printf '%s\n' "$$" > \(quote(pidFile.path))
          printf '%s\n' "$6/0001-partial.patch"
          if [ -f \(quote(root.appendingPathComponent(".git/hold-export").path)) ]; then
            /bin/sleep 30 & child=$!
            trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
            wait "$child"
          fi
          printf 'controlled export failure\n' >&2
          exit 19
        fi
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let wrapped=GitRepository(root:root,executable:helper)
        for cancelled in [false,true] {
            let token=OperationCancellation(),folder=root.appendingPathComponent(cancelled ? "cancelled":"failed")
            if cancelled {try Data().write(to:root.appendingPathComponent(".git/hold-export"))}
            do {
                _=try await wrapped.formatPatchFiles(selection:.number(1),to:folder,cancellation:token,onOutput:{chunk in if cancelled && String(decoding:chunk.data,as:UTF8.self).contains("0001-partial.patch") {token.cancel()}})
                XCTFail("Failed export produced a receipt")
            }catch let failure as GitCommandCancellationFailure {XCTAssertTrue(cancelled);XCTAssertTrue(failure.result.text.contains("0001-partial.patch"))}
            catch let failure as GitFailure {XCTAssertFalse(cancelled);XCTAssertEqual(failure.code,19)}
            XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("0001-partial.patch")),Data("partial".utf8))
            let pid=try XCTUnwrap(Int32(try String(contentsOf:pidFile,encoding:.utf8).trimmingCharacters(in:.newlines)));XCTAssertNotEqual(kill(pid,0),0)
        }
        let token=OperationCancellation();token.cancel()
        do {_=try await wrapped.formatPatchFiles(selection:.number(1),to:root.appendingPathComponent("precancelled"),cancellation:token);XCTFail("Precancelled export ran")}catch OperationCancellationFailure.cancelled {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("precancelled").path))
    }
}
