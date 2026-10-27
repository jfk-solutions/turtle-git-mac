// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class RawHistoricalMaterializationTests:XCTestCase {
    private struct Fixture {
        let root:URL,repo:GitRepository,old:String,new:String,oldKey:String,key:String,sibling:String,blob:String
        let oldBytes:Data,bytes:Data,path:Data
    }
    private func blob(_ repo:GitRepository,_ bytes:Data)async throws->String {
        try await repo.run(["hash-object","-w","--stdin"],input:bytes).text.trimmingCharacters(in:.newlines)
    }
    private func tree(_ repo:GitRepository,_ entries:[(String,String,Data)])async throws->String {
        var data=Data()
        for (mode,oid,path) in entries {data.append(Data("\(mode) blob \(oid)\t".utf8));data.append(path);data.append(0)}
        return try await repo.run(["mktree","-z"],input:data).text.trimmingCharacters(in:.newlines)
    }
    private func fixture()async throws->Fixture {
        let(root,initial,_)=try await GitPatchTests().fixture()
        do {
            let repo=GitRepository(root:root,executable:initial.executable,askpass:nil,libgit2Configuration:.init(mask:0))
            let raw=Data([0xff])+Data(" new ' $()\n.txt".utf8),oldRaw=Data([0xfe])+Data(" old.txt".utf8),replacement=Data("\u{fffd} new ' $()\n.txt".utf8)
            let a=Data("original source\r\nkeep original lines\nlast source\n".utf8),b=Data("changed source\r\nkeep original lines\nlast source\n".utf8)
            let oldBlob=try await blob(repo,a),newBlob=try await blob(repo,b),other=try await blob(repo,Data("replacement sibling\n".utf8))
            let t1=try await tree(repo,[("100644",oldBlob,oldRaw),("100644",other,replacement)])
            let c1=try await repo.run(["commit-tree",t1],input:Data("raw materialization birth\n".utf8)).text.trimmingCharacters(in:.newlines)
            let t2=try await tree(repo,[("100755",newBlob,raw),("100644",other,replacement)])
            let c2=try await repo.run(["commit-tree",t2,"-p",c1],input:Data("raw rename edit\n".utf8)).text.trimmingCharacters(in:.newlines)
            _ = try await repo.run(["update-ref","refs/heads/raw-materialization",c2])
            return Fixture(root:root,repo:repo,old:c1,new:c2,oldKey:try RepositoryBrowserGitPath(rawData:oldRaw).key,key:try RepositoryBrowserGitPath(rawData:raw).key,sibling:String(decoding:replacement,as:UTF8.self),blob:newBlob,oldBytes:a,bytes:b,path:raw)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}

    func testHistoricalReadersComparisonsScopesAndBothPatchBackendsRetainExactKeys()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let before=try Data(contentsOf:f.root.appendingPathComponent(".git/index"))
        let content=try await f.repo.historicalFile(revision:f.new,path:f.key)
        XCTAssertEqual(content.bytes,f.bytes);XCTAssertEqual(content.objectID,f.blob);XCTAssertEqual(content.path,f.key);XCTAssertEqual(content.mode,"100755")
        let comparison=try await f.repo.preparedPathComparison(from:.revision(f.old),fromPath:f.oldKey,to:.revision(f.new),toPath:f.key)
        let pair=try await f.repo.comparisonFile(comparison,path:f.key)
        XCTAssertEqual(pair.base.bytes,f.oldBytes);XCTAssertEqual(pair.destination.bytes,f.bytes)
        XCTAssertEqual(pair.base.path,f.oldKey);XCTAssertEqual(pair.destination.objectID,f.blob)
        let scoped=try await f.repo.revisionComparison(from:.revision(f.old),to:.revision(f.new),paths:[f.oldKey,f.key])
        XCTAssertFalse(scoped.files.isEmpty);XCTAssertFalse(scoped.files.contains{$0.path==f.sibling})
        XCTAssertTrue(scoped.files.allSatisfy{!$0.isPathRepresentable})
        let selected=try await f.repo.revisionFileComparison(from:.revision(f.old),to:.revision(f.new),paths:[f.key])
        XCTAssertEqual(selected.files.first?.path,f.key)
        for backend in [GitLibGit2Configuration(mask:0),GitLibGit2Configuration(mask:1<<4)] {
            let patch=try await f.repo.revisionComparisonPatchData(scoped,backend:backend)
            let text=String(decoding:patch,as:UTF8.self)
            let label=backend.requests(.diff) ? "selected-libgit2-4":"command-line"
            let diagnostic="backend="+label+" bytes="+String(patch.count)+" CR="+String(patch.filter{$0==13}.count)+" patchBase64="+patch.base64EncodedString()
            print("Raw historical patch receipt: backend=\(label) bytes=\(patch.count) CR=\(patch.filter{$0==13}.count)")
            // Assert full signed byte lines, not a String substring ending
            // inside the CRLF extended grapheme cluster.
            XCTAssertNotNil(patch.range(of:Data("+changed source\r\n".utf8)),diagnostic)
            XCTAssertNotNil(patch.range(of:Data("-original source\r\n".utf8)),diagnostic)
            XCTAssertTrue(text.contains("\\377"));XCTAssertTrue(text.contains("\\376"));XCTAssertFalse(text.contains("replacement sibling"))
            XCTAssertFalse(patch.contains(0))
            let entry=LogEntry(hash:f.new,author:"",date:"",subject:"",parents:[f.old])
            let files=try await f.repo.files(in:entry,backend:.init(mask:0))
            let one=try await f.repo.revisionFileDiffData(entry,files:files,backend:backend)
            XCTAssertTrue(String(decoding:one,as:UTF8.self).contains("changed source"))
            let preview=try await f.repo.logPatchPreviewData(entry,files:files,backend:backend)
            XCTAssertTrue(String(decoding:preview,as:UTF8.self).contains("changed source"))
        }
        let sibling=try await f.repo.historicalFile(revision:f.new,path:f.sibling)
        XCTAssertEqual(sibling.bytes,Data("replacement sibling\n".utf8));XCTAssertNotEqual(sibling.objectID,content.objectID)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),before)
    }

    func testFilteredMaterializationKeepsOriginalOIDAndExactPercentFPathAcrossPinnedBrowserReceipt()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let capture=f.root.appendingPathComponent("filter-path"),script=f.root.appendingPathComponent("private-filter")
        try Data(("#!/bin/sh\nprintf '%s\\0' \"$1\" > "+quote(capture.path)+"\n/usr/bin/tr 'a-z' 'A-Z'\n").utf8).write(to:script)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:script.path)
        _ = try await f.repo.run(["config","filter.raw-materialization.smudge",quote(script.path)+" %f"])
        _ = try await f.repo.run(["config","filter.raw-materialization.required","true"])
        try Data("*.txt filter=raw-materialization\n".utf8).write(to:f.root.appendingPathComponent(".git/info/attributes"))
        let browser=try await f.repo.browseRepository(revision:"refs/heads/raw-materialization")
        let row=try XCTUnwrap(browser.entries.first{$0.rawPath==f.path})
        _ = try await f.repo.run(["update-ref","refs/heads/raw-materialization",f.old])
        let cli=try await f.repo.materializedRepositoryBrowserFile(browser,entry:row,backend:.init(mask:0))
        XCTAssertEqual(cli.bytes,f.bytes);XCTAssertEqual(cli.objectID,f.blob)
        XCTAssertFalse(FileManager.default.fileExists(atPath:capture.path))
        let filtered=try await f.repo.materializedRepositoryBrowserFile(browser,entry:row,backend:.init(mask:1<<9))
        XCTAssertEqual(filtered.path,f.key);XCTAssertEqual(filtered.revision,.revision(f.new));XCTAssertEqual(filtered.objectID,f.blob)
        XCTAssertEqual(filtered.bytes,Data("CHANGED SOURCE\r\nKEEP ORIGINAL LINES\nLAST SOURCE\n".utf8))
        XCTAssertEqual(try Data(contentsOf:capture),f.path+Data([0]))
        let stored=try await f.repo.repositoryBrowserFile(browser,entry:row)
        XCTAssertEqual(stored.path,f.key);XCTAssertEqual(stored.bytes,f.bytes);XCTAssertEqual(stored.objectID,f.blob)
        // The selected helper's current-attribute policy is live, while blob
        // and revision identity remain pinned to the accepted Browser receipt.
        try Data("*.txt -filter\n".utf8).write(to:f.root.appendingPathComponent(".git/info/attributes"))
        let unfiltered=try await f.repo.materializedHistoricalFile(revision:f.new,path:f.key,backend:.init(mask:1<<9))
        XCTAssertEqual(unfiltered.bytes,f.bytes);XCTAssertEqual(unfiltered.objectID,f.blob)
    }

    func testWorkingFilesystemBoundariesAndHostilePrivatePacketsStillRefuse()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        do {_ = try await f.repo.revisionFileComparison(from:.revision(f.old),to:.workingTree,paths:[f.key]);XCTFail("Raw worktree scope admitted")} catch is WorkingFileRestoreFailure {}
        do {_ = try await f.repo.preparedPathComparison(from:.revision(f.old),fromPath:f.oldKey,to:.workingTree,toPath:f.key);XCTFail("Raw worktree comparison admitted")} catch is WorkingFileRestoreFailure {}
        let entry=LogEntry(hash:f.new,author:"",date:"",subject:"",parents:[f.old])
        do {_ = try await f.repo.revisionDiffData(entry,path:f.key,workingTree:true);XCTFail("Raw worktree patch admitted")} catch is WorkingFileRestoreFailure {}
        let helper=try XCTUnwrap(GitLibGit2Configuration(mask:1<<9).executor(for:.getOneFile))
        let bad=[Data([0]),Data("../escape".utf8),Data("/absolute".utf8),Data("a//b".utf8),Data("a/./b".utf8)]
        for path in bad {
            let request=try JSONSerialization.data(withJSONObject:["version":1,"oid":f.blob,"pathData":path.base64EncodedString()])
            do {_ = try await f.repo.run(["turtlegit-materialize-blob"],input:request,executorOverride:helper);XCTFail("Hostile byte path admitted")} catch is GitFailure {}
        }
        let malformed:[[String:Any]]=[["version":true,"oid":f.blob,"pathData":f.path.base64EncodedString()],["version":1,"oid":f.blob,"pathData":"%%%"],["version":1,"oid":f.blob,"pathData":f.path.base64EncodedString(),"extra":0]]
        for request in malformed {
            do {_ = try await f.repo.run(["turtlegit-materialize-blob"],input:JSONSerialization.data(withJSONObject:request),executorOverride:helper);XCTFail("Malformed private packet admitted")} catch is GitFailure {}
        }
        let worktree=try JSONSerialization.data(withJSONObject:["version":2,"old":f.old,"new":"WORKTREE","pathData":[f.path.base64EncodedString()],"noPrefix":false])
        do {_ = try await f.repo.run(["turtlegit-unified-diff"],input:worktree,executorOverride:helper);XCTFail("Byte-path worktree packet admitted")} catch is GitFailure {}
    }

    func testSymlinkSourceBytesAndCancellationDrainActualFilteredChild()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let linkPath=Data([0xff])+Data(".link".utf8),linkBytes=Data([46,46,47,0xfe,10])
        let linkOID=try await blob(f.repo,linkBytes),linkTree=try await tree(f.repo,[("120000",linkOID,linkPath)])
        let linkKey=try RepositoryBrowserGitPath(rawData:linkPath).key
        for backend in [GitLibGit2Configuration(mask:0),GitLibGit2Configuration(mask:1<<9)] {
            let link=try await f.repo.materializedHistoricalFile(revision:linkTree,path:linkKey,backend:backend)
            XCTAssertEqual(link.bytes,linkBytes);XCTAssertEqual(link.mode,"120000");XCTAssertEqual(link.objectID,linkOID)
        }
        let pidFile=f.root.appendingPathComponent("filter-pid"),script=f.root.appendingPathComponent("held-filter")
        try Data(("#!/bin/sh\nprintf '%s' \"$$\" > "+quote(pidFile.path)+"\nexec /bin/sleep 30\n").utf8).write(to:script)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:script.path)
        _ = try await f.repo.run(["config","filter.held-raw.smudge",quote(script.path)+" %f"])
        _ = try await f.repo.run(["config","filter.held-raw.required","true"])
        try Data("*.txt filter=held-raw\n".utf8).write(to:f.root.appendingPathComponent(".git/info/attributes"))
        let token=OperationCancellation();defer{token.cancel()}
        let pending=Task {try await f.repo.materializedHistoricalFile(revision:f.new,path:f.key,cancellation:token,backend:.init(mask:1<<9))}
        let deadline=Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath:pidFile.path),Date()<deadline {try await Task.sleep(nanoseconds:10_000_000)}
        token.cancel()
        do {_ = try await pending.value;XCTFail("Canceled materialization succeeded")} catch is GitCommandCancellationFailure {} catch is OperationCancellationFailure {}
        let pid=try XCTUnwrap(Int32(String(contentsOf:pidFile,encoding:.utf8)))
        let gone=Date().addingTimeInterval(3)
        while kill(pid,0)==0,Date()<gone {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)
    }
}
