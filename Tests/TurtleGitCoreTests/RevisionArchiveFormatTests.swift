import XCTest
import Darwin
@testable import TurtleGitCore

private final class ArchiveFormatReceipts: @unchecked Sendable {
    private let lock=NSLock()
    private var commandPaths:[URL]=[]
    private var settled:[RevisionArchiveCommandCompletion]=[]
    func command(_ value:GitCommandInvocation) {
        lock.lock();defer{lock.unlock()}
        XCTAssertFalse(value.arguments.contains(where:{$0.hasPrefix("--format=")}))
        if let argument=value.arguments.first(where:{$0.hasPrefix("--output=")}) {
            commandPaths.append(URL(fileURLWithPath:String(argument.dropFirst("--output=".count))))
        }
    }
    func finished(_ value:RevisionArchiveCommandCompletion) {lock.lock();settled.append(value);lock.unlock()}
    var paths:[URL] {lock.lock();defer{lock.unlock()};return commandPaths}
    var completions:[RevisionArchiveCommandCompletion] {lock.lock();defer{lock.unlock()};return settled}
}

final class RevisionArchiveFormatTests:XCTestCase {
    private struct Fixture {
        let root:URL,repo:GitRepository,scope:String,head:String,index:Data
        let payload=Data([0,255,13,10,0x81])
    }
    private func fixture() async throws->Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Archive formats ' 雪 "+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        do {
            let git=ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map{URL(fileURLWithPath:$0)} ?? URL(fileURLWithPath:"/usr/bin/git")
            let repo=GitRepository(root:root,executable:git)
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Archive Formats"),("user.email","archive@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tar.umask","0000")] {
                _ = try await repo.run(["config",key,value])
            }
            let scope="nested ' 雪",folder=root.appendingPathComponent(scope)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            try Data([0,255,13,10,0x81]).write(to:folder.appendingPathComponent("payload.bin"))
            try Data("private\n".utf8).write(to:folder.appendingPathComponent("secret"))
            try Data("$Format:%H$\n".utf8).write(to:folder.appendingPathComponent("version"))
            try Data("secret export-ignore\nversion export-subst\n".utf8).write(to:folder.appendingPathComponent(".gitattributes"))
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to:folder.appendingPathComponent("run.sh"))
            try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:folder.appendingPathComponent("run.sh").path)
            try FileManager.default.createSymbolicLink(atPath:folder.appendingPathComponent("link").path,withDestinationPath:"payload.bin")
            try await repo.stage([scope]);_ = try await repo.commit(message:"archive formats")
            let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            try Data("dirty working bytes".utf8).write(to:folder.appendingPathComponent("payload.bin"))
            return Fixture(root:root,repo:repo,scope:scope,head:head,index:index)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private func tool(_ name:String,_ arguments:[String])throws->Data {
        try BundledTextHelper.capture(executable:URL(fileURLWithPath:"/usr/bin/env"),arguments:["LC_ALL=en_US.UTF-8","/usr/bin/"+name]+arguments)
    }
    private func assertCleanup(_ receipts:ArchiveFormatReceipts,destination:URL,file:StaticString=#filePath,line:UInt=#line)throws {
        let path=try XCTUnwrap(receipts.paths.first,file:file,line:line)
        XCTAssertEqual(receipts.paths.count,1,file:file,line:line)
        XCTAssertEqual(path.lastPathComponent.utf8.map{$0},destination.lastPathComponent.utf8.map{$0},file:file,line:line)
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.path),file:file,line:line)
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.deletingLastPathComponent().path),file:file,line:line)
    }
    private func assertContents(_ fixture:Fixture,archive:URL,scoped:Bool) throws {
        let extracted=fixture.root.appendingPathComponent("extract-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:extracted,withIntermediateDirectories:false)
        // macOS's older unzip performs locale-dependent filename conversion.
        // BSD tar/libarchive independently reads ZIP and TAR/gzip while retaining
        // UTF-8 names, Unix modes and symlinks. Magic checks below still establish
        // each actual container type separately from this extraction oracle.
        _ = try tool("tar",["-xf",archive.path,"-C",extracted.path])
        let folder=scoped ? extracted:extracted.appendingPathComponent(fixture.scope)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("payload.bin")),fixture.payload)
        XCTAssertEqual(try String(contentsOf:folder.appendingPathComponent("version"),encoding:.utf8),fixture.head+"\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent("secret").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:folder.appendingPathComponent("link").path),"payload.bin")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:folder.appendingPathComponent("run.sh").path)[.posixPermissions] as? NSNumber)?.intValue,0o755)
        if scoped {XCTAssertFalse(FileManager.default.fileExists(atPath:extracted.appendingPathComponent(fixture.scope).path))}
    }
    func testFilenameInferenceProducesZipTarGzipAndDefaultTarWithScopedAttributes() async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let cases:[(String,String,Bool)]=[("release.zip","zip",false),("release.tar","tar",true),("release.tar.gz","gzip",true),("release.tgz","gzip",false),("release.unrecognized-turtle","tar",false),("release-no-suffix","tar",true)]
        for (name,kind,scoped) in cases {
            let archive=f.root.appendingPathComponent(name),receipts=ArchiveFormatReceipts()
            _ = try await f.repo.archiveRevision(directory:scoped ? f.scope:"",to:archive,onCommand:{receipts.command($0)},onCommandFinished:{receipts.finished($0)})
            let bytes=try Data(contentsOf:archive)
            if kind=="zip" {XCTAssertEqual(Array(bytes.prefix(4)),[0x50,0x4b,3,4])}
            else if kind=="gzip" {XCTAssertEqual(Array(bytes.prefix(2)),[0x1f,0x8b])}
            else {XCTAssertGreaterThan(bytes.count,512);XCTAssertEqual(String(decoding:bytes[257..<262],as:UTF8.self),"ustar")}
            try assertContents(f,archive:archive,scoped:scoped)
            XCTAssertEqual(receipts.completions.count,1);XCTAssertTrue(try XCTUnwrap(receipts.completions.first).success)
            try assertCleanup(receipts,destination:archive)
        }
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),f.index)
        let head=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(head,f.head)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(f.scope+"/payload.bin")),Data("dirty working bytes".utf8))
    }
    func testConfiguredCompoundSuffixAndLiteralDestinationUseGitArchiveFilter() async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _ = try await f.repo.run(["config","tar.tar.fixture-gzip.command","/usr/bin/gzip -n -c"])
        let archive=f.root.appendingPathComponent("release ' [雪]\n*.tar.fixture-gzip"),receipts=ArchiveFormatReceipts()
        _ = try await f.repo.archiveRevision(directory:f.scope,to:archive,onCommand:{receipts.command($0)},onCommandFinished:{receipts.finished($0)})
        XCTAssertEqual(Array(try Data(contentsOf:archive).prefix(2)),[0x1f,0x8b])
        try assertContents(f,archive:archive,scoped:true)
        try assertCleanup(receipts,destination:archive)
    }
    func testFilteredFailureAndPostCommandCancellationOrFinalizationFailurePreserveExistingArchive() async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _ = try await f.repo.run(["config","tar.tar.fixture-fail.command","/bin/sh -c 'printf partial; exit 23'"])
        let failing=f.root.appendingPathComponent("existing.tar.fixture-fail"),old=Data("existing destination".utf8),failed=ArchiveFormatReceipts()
        try old.write(to:failing)
        do {_ = try await f.repo.archiveRevision(to:failing,onCommand:{failed.command($0)},onCommandFinished:{failed.finished($0)});XCTFail("Failing archive filter succeeded")}
        catch {XCTAssertEqual(try Data(contentsOf:failing),old)}
        XCTAssertEqual(failed.completions.count,1);XCTAssertFalse(try XCTUnwrap(failed.completions.first).success)
        try assertCleanup(failed,destination:failing)
        for cancel in [true,false] {
            let destination=f.root.appendingPathComponent("existing.tar.gz"),token=OperationCancellation(),receipts=ArchiveFormatReceipts()
            try old.write(to:destination)
            do {
                _ = try await f.repo.archiveRevision(to:destination,cancellation:token,onCommand:{receipts.command($0)},onCommandFinished:{receipts.finished($0)},beforeFinalization:{
                    XCTAssertEqual(receipts.completions.count,1);XCTAssertTrue(try XCTUnwrap(receipts.completions.first).success)
                    XCTAssertEqual(try Data(contentsOf:destination),old)
                    if cancel {token.cancel()}else{throw CocoaError(.fileWriteNoPermission)}
                })
                XCTFail("Finalization unexpectedly succeeded")
            } catch {XCTAssertEqual(try Data(contentsOf:destination),old)}
            try assertCleanup(receipts,destination:destination)
        }
    }
    func testCancellationDrainsActualConfiguredArchiveFilterAndRemovesReplacementWorkspace() async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let script=f.root.appendingPathComponent(".git/archive-filter"),marker=f.root.appendingPathComponent(".git/archive-filter-pid")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        try Data(("#!/bin/sh\nprintf '%s\\n' \"$$\" > "+quote(marker.path)+"\nwhile :; do /bin/sleep 0.05; done\n").utf8).write(to:script)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:script.path)
        _ = try await f.repo.run(["config","tar.owned-wait.command",quote(script.path)])
        let destination=f.root.appendingPathComponent("existing.owned-wait"),original=Data("preserve the original archive".utf8)
        try original.write(to:destination)
        let token=OperationCancellation(),receipts=ArchiveFormatReceipts()
        let task=Task { ()->Error? in
            do {_ = try await f.repo.archiveRevision(to:destination,cancellation:token,onCommand:{receipts.command($0)},onCommandFinished:{receipts.finished($0)});return nil}
            catch {return error}
        }
        do {
            let deadline=Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath:marker.path),Date()<deadline {try await Task.sleep(nanoseconds:5_000_000)}
            let pid=try XCTUnwrap(Int32(try String(contentsOf:marker,encoding:.utf8).trimmingCharacters(in:.newlines)))
            XCTAssertTrue(receipts.completions.isEmpty,"Settlement cannot precede the actual filter's termination")
            token.cancel()
            let failure=await task.value
            XCTAssertNotNil(failure)
            let drainDeadline=Date().addingTimeInterval(2)
            while kill(pid,0)==0,Date()<drainDeadline {try await Task.sleep(nanoseconds:5_000_000)}
            let status=kill(pid,0),failureCode=errno
            XCTAssertEqual(status,-1);XCTAssertEqual(failureCode,ESRCH)
        } catch {
            token.cancel();_ = await task.value;throw error
        }
        XCTAssertEqual(receipts.completions.count,1)
        let receipt=try XCTUnwrap(receipts.completions.first)
        XCTAssertFalse(receipt.success);XCTAssertTrue(receipt.cancelled)
        XCTAssertEqual(try Data(contentsOf:destination),original)
        try assertCleanup(receipts,destination:destination)
    }
}
