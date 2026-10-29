// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class RepositoryBrowserArchiveTests:XCTestCase {
    private struct Fixture {
        let root:URL,repository:GitRepository,snapshot:RepositoryBrowserSnapshot,raw:RepositoryBrowserGitPath,commit:String
    }
    private func fixture()async throws->Fixture {
        let (root,repository,_)=try await GitPatchTests().fixture()
        do {
            let raw=try RepositoryBrowserGitPath(rawData:Data([114,97,119,45,255]))
            let entries:[(Data,Data,String)]=[
                (Data(".gitattributes".utf8),Data("*/private export-ignore\n*/version export-subst\n".utf8),"100644"),
                (raw.rawData+Data("/binary".utf8),Data([0,255,1,10]),"100644"),
                (raw.rawData+Data("/private".utf8),Data("excluded".utf8),"100644"),
                (raw.rawData+Data("/version".utf8),Data("$Format:%H$\n".utf8),"100644"),
                (raw.rawData+Data("/run".utf8),Data("#!/bin/sh\n".utf8),"100755"),
                (raw.rawData+Data("/link".utf8),Data("binary".utf8),"120000"),
                (Data("historical-gone/file".utf8),Data("historical bytes".utf8),"100644"),
                (Data("unselected".utf8),Data("outside scope".utf8),"100644")]
            var packet=Data()
            for (path,bytes,mode) in entries {
                let oid=try await repository.run(["hash-object","-w","--stdin"],input:bytes).text.trimmingCharacters(in:.newlines)
                packet.append(Data((mode+" "+oid+"\t").utf8));packet.append(path);packet.append(0)
            }
            _ = try await repository.run(["update-index","-z","--index-info"],input:packet)
            let tree=try await repository.run(["write-tree"]).text.trimmingCharacters(in:.newlines)
            let parent=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            let commit=try await repository.run(["commit-tree",tree,"-p",parent],input:Data("raw archive fixture\n".utf8)).text.trimmingCharacters(in:.newlines)
            _ = try await repository.run(["update-ref","HEAD",commit])
            let gone=root.appendingPathComponent("historical-gone",isDirectory:true)
            try FileManager.default.createDirectory(at:gone,withIntermediateDirectories:true)
            try Data("historical bytes".utf8).write(to:gone.appendingPathComponent("file"))
            try FileManager.default.removeItem(at:gone)
            let snapshot=try await repository.browseRepository(revision:commit,backend:.init(enabled:false))
            return Fixture(root:root,repository:repository,snapshot:snapshot,raw:raw,commit:commit)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private struct TarMember {let mode:Int,type:UInt8,bytes:Data}
    private func tarMembers(_ data:Data)throws->[Data:TarMember] {
        func field(_ block:Data,_ range:Range<Int>)->Data {Data(block[range].prefix(while:{$0 != 0}))}
        var result:[Data:TarMember]=[:],offset=0
        while offset+512<=data.count {
            let header=Data(data[offset..<offset+512]);if header.allSatisfy({$0==0}) {break}
            let size=try XCTUnwrap(Int(String(decoding:field(header,124..<136),as:UTF8.self).trimmingCharacters(in:.whitespaces),radix:8))
            let mode=try XCTUnwrap(Int(String(decoding:field(header,100..<108),as:UTF8.self).trimmingCharacters(in:.whitespaces),radix:8))
            guard size>=0,offset+512+size<=data.count else{throw RevisionArchiveFailure.destination}
            let type=header[156]
            if type != 120 && type != 103 {
                var name=field(header,0..<100),prefix=field(header,345..<500)
                if !prefix.isEmpty {prefix.append(47);prefix.append(name);name=prefix}
                let body=type==50 ? field(header,157..<257):Data(data[offset+512..<offset+512+size])
                result[name]=TarMember(mode:mode,type:type,bytes:body)
            }
            offset+=512+((size+511)/512)*512
        }
        return result
    }
    private func zipMemberNames(_ data:Data)->[Data] {
        let signature=Data([0x50,0x4b,1,2]);var cursor=0,result:[Data]=[]
        func u16(_ offset:Int)->Int {Int(data[offset]) | Int(data[offset+1])<<8}
        while cursor+46<=data.count,let match=data.range(of:signature,in:cursor..<data.count) {
            let start=match.lowerBound;guard start+46<=data.count else{break}
            let length=u16(start+28),extra=u16(start+30),comment=u16(start+32)
            guard start+46+length+extra+comment<=data.count else{break}
            result.append(Data(data[start+46..<start+46+length]));cursor=start+46+length+extra+comment
        }
        return result
    }
    func testPinnedRawFolderTarPreservesOriginalNamesAttributesModesAndSymlinks()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        // Git archive derives tar modes from tar.umask rather than copying
        // the index mode verbatim. Capture a private explicit 0022 policy so
        // executable and symlink permission assertions have one exact oracle.
        _ = try await f.repository.run(["config","tar.umask","0022"])
        let index=try Data(contentsOf:f.root.appendingPathComponent(".git/index")),destination=f.root.appendingPathComponent("safe-name.tar")
        _ = try await f.repository.run(["read-tree","--empty"])
        let changedIndex=try Data(contentsOf:f.root.appendingPathComponent(".git/index"))
        let emptyTree=try await f.repository.run(["write-tree"]).text.trimmingCharacters(in:.newlines)
        let advanced=try await f.repository.run(["commit-tree",emptyTree,"-p",f.commit],input:Data("advance HEAD without old folders\n".utf8)).text.trimmingCharacters(in:.newlines)
        _ = try await f.repository.run(["update-ref","HEAD",advanced])
        _ = try await f.repository.archiveRepositoryBrowser(f.snapshot,directory:f.raw.key,to:destination)
        let members=try tarMembers(Data(contentsOf:destination)),prefix=f.raw.rawData+Data([47])
        XCTAssertEqual(members[prefix+Data("binary".utf8)]?.bytes,Data([0,255,1,10]))
        XCTAssertEqual(members[prefix+Data("version".utf8)]?.bytes,Data((f.commit+"\n").utf8))
        XCTAssertNil(members[prefix+Data("private".utf8)]);XCTAssertNil(members[Data("unselected".utf8)])
        XCTAssertEqual(members[prefix+Data("run".utf8)]?.mode,0o755)
        XCTAssertEqual(members[prefix+Data("link".utf8)]?.type,50);XCTAssertEqual(members[prefix+Data("link".utf8)]?.bytes,Data("binary".utf8))
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),changedIndex)
        XCTAssertNotEqual(index,changedIndex)
    }
    func testRawFolderZipHeadersAndWholeRootUseExactStoredMemberPaths()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let destination=f.root.appendingPathComponent("safe-name.zip")
        _ = try await f.repository.archiveRepositoryBrowser(f.snapshot,directory:f.raw.key,to:destination)
        let names=zipMemberNames(try Data(contentsOf:destination)),prefix=f.raw.rawData+Data([47])
        XCTAssertTrue(names.contains(prefix+Data("binary".utf8)));XCTAssertFalse(names.contains(prefix+Data("private".utf8)))
        XCTAssertTrue(names.contains{String(data:$0,encoding:.utf8)==nil},"Inspect original ZIP member headers, not replacement-decoded names")
        let whole=f.root.appendingPathComponent("whole.tar")
        _ = try await f.repository.archiveRepositoryBrowser(f.snapshot,directory:"",to:whole)
        XCTAssertNotNil(try tarMembers(Data(contentsOf:whole))[Data("unselected".utf8)])
    }
    func testHistoricalDeletedDirectoryAndBareRepositoryNeverRequireWorkingFolder()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let destination=f.root.appendingPathComponent("deleted.tar")
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("historical-gone").path))
        _ = try await f.repository.archiveRepositoryBrowser(f.snapshot,directory:"historical-gone",to:destination)
        XCTAssertEqual(try tarMembers(Data(contentsOf:destination))[Data("historical-gone/file".utf8)]?.bytes,Data("historical bytes".utf8))
        let bare=f.root.appendingPathComponent("bare.git")
        _ = try await f.repository.run(["clone","--bare",f.root.path,bare.path])
        let repository=GitRepository(root:bare,executable:f.repository.executable)
        let snapshot=try await repository.browseRepository(revision:f.commit,backend:.init(enabled:false)),archive=f.root.appendingPathComponent("bare.tar")
        _ = try await repository.archiveRepositoryBrowser(snapshot,directory:f.raw.key,to:archive)
        XCTAssertNotNil(try tarMembers(Data(contentsOf:archive))[f.raw.rawData+Data("/binary".utf8)])
    }
    func testSnapshotTreeIdentityAndGitMetadataDestinationRefuse()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let forged=RepositoryBrowserSnapshot(root:f.snapshot.root,revision:f.snapshot.revision,objectID:f.snapshot.objectID,
            treeID:String(repeating:"0",count:40),directory:f.snapshot.directory,bare:f.snapshot.bare,entries:f.snapshot.entries)
        let destination=f.root.appendingPathComponent("refused.tar")
        do {_ = try await f.repository.archiveRepositoryBrowser(forged,directory:f.raw.key,to:destination);XCTFail("Accepted inconsistent pinned tree")}
        catch RevisionArchiveFailure.revision {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        let metadata=f.root.appendingPathComponent(".git/refused.tar")
        do {_ = try await f.repository.archiveRepositoryBrowser(f.snapshot,directory:f.raw.key,to:metadata);XCTFail("Archived into Git metadata")}
        catch RevisionArchiveFailure.destination {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:metadata.path))
    }
    func testScopeRefusalCancellationAndDestinationCASDoNotOverwriteFiles()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let output=f.root.appendingPathComponent("protected.tar"),original=Data("original".utf8)
        try original.write(to:output)
        do {_ = try await f.repository.archiveRepositoryBrowser(f.snapshot,directory:"unselected",to:output);XCTFail("Accepted file as directory scope")}
        catch RevisionArchiveFailure.directory {}
        let token=OperationCancellation()
        do {_ = try await f.repository.archiveRepositoryBrowser(f.snapshot,directory:f.raw.key,to:output,cancellation:token,beforeFinalization:{token.cancel()});XCTFail("Published canceled archive")}
        catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf:output),original)
        do {_ = try await f.repository.archiveRepositoryBrowser(f.snapshot,directory:f.raw.key,to:output,beforeFinalization:{try Data("external".utf8).write(to:output,options:.atomic)});XCTFail("Overwrote replacement destination")}
        catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try Data(contentsOf:output),Data("external".utf8))
        let absent=f.root.appendingPathComponent("appeared.tar")
        do {_ = try await f.repository.archiveRepositoryBrowser(f.snapshot,directory:f.raw.key,to:absent,beforeFinalization:{try Data("appeared".utf8).write(to:absent)});XCTFail("Overwrote appeared destination")}
        catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try Data(contentsOf:absent),Data("appeared".utf8))
    }
}
