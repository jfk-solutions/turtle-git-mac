// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class RawHistoricalPathTests:XCTestCase {
    private func blob(_ repo:GitRepository,_ bytes:Data)async throws->String {
        try await repo.run(["hash-object","-w","--stdin"],input:bytes).text.trimmingCharacters(in:.newlines)
    }
    private func tree(_ repo:GitRepository,_ entries:[(Data,String)])async throws->String {
        var input=Data()
        for (path,oid) in entries {input.append(Data("100644 blob \(oid)\t".utf8));input.append(path);input.append(0)}
        return try await repo.run(["mktree","-z"],input:input).text.trimmingCharacters(in:.newlines)
    }
    private func commit(_ repo:GitRepository,_ tree:String,parent:String?,message:String)async throws->String {
        try await repo.run(["commit-tree",tree]+(parent.map{["-p",$0]} ?? []),input:Data((message+"\n").utf8)).text.trimmingCharacters(in:.newlines)
    }
    func testRawRenameHistoryBlameAndSelectedHelperMetadataKeepDistinctSiblings()async throws {
        let(root,initial,workingPath)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:initial.root,executable:initial.executable,askpass:nil,libgit2Configuration:.init(mask:0))
        let old=Data([0xff])+Data(" old\t.txt".utf8),new=Data([0xfe])+Data(" new\n.txt".utf8),sibling=Data("\u{fffd} new\n.txt".utf8)
        let oldKey=try RepositoryBrowserGitPath(rawData:old).key,newKey=try RepositoryBrowserGitPath(rawData:new).key
        let original=Data("first annotation\r\nsecond annotation\nthird annotation\nlast annotation".utf8)
        let changed=Data("first annotation\r\nCHANGED annotation\nthird annotation\nlast annotation".utf8)
        let firstBlob=try await blob(repo,original),changedBlob=try await blob(repo,changed),otherBlob=try await blob(repo,Data("replacement sibling\n".utf8))
        let t1=try await tree(repo,[(old,firstBlob),(sibling,otherBlob)])
        let c1=try await commit(repo,t1,parent:nil,message:"birth raw")
        let t2=try await tree(repo,[(new,firstBlob),(sibling,otherBlob)])
        let c2=try await commit(repo,t2,parent:c1,message:"rename raw")
        let t3=try await tree(repo,[(new,changedBlob),(sibling,otherBlob)])
        let c3=try await commit(repo,t3,parent:c2,message:"edit raw")
        _ = try await repo.run(["update-ref","refs/heads/raw-history",c3])
        // Exercise Git's byte-framed index input in an owned alternate index,
        // never materialize malformed names on the host filesystem.
        let alternate=root.appendingPathComponent("raw-index")
        let environment=["GIT_INDEX_FILE":alternate.path]
        _ = try await repo.run(["read-tree","--empty"],environmentOverrides:environment)
        var records=Data()
        for (name,oid) in [(new,changedBlob),(sibling,otherBlob)] {records.append(Data("100644 \(oid)\t".utf8));records.append(name);records.append(0)}
        _ = try await repo.run(["update-index","-z","--index-info"],environmentOverrides:environment,input:records)
        let indexTree=try await repo.run(["write-tree"],environmentOverrides:environment).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(indexTree,t3)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),work=try Data(contentsOf:root.appendingPathComponent(workingPath))
        var history=HistoryOptions();history.path=newKey;history.endRevision=c3;history.limit = -1;history.walk.followRenames=true
        let followed=try await repo.history(options:history)
        XCTAssertEqual(followed.map(\.hash),[c3,c2,c1])
        history.walk.followRenames=false
        let scoped=try await repo.history(options:history)
        XCTAssertEqual(scoped.map(\.hash),[c3,c2])
        history.path=String(decoding:sibling,as:UTF8.self)
        let siblingHistory=try await repo.history(options:history)
        XCTAssertEqual(siblingHistory.map(\.hash),[c1])
        history.path=nil;history.paths=[newKey,String(decoding:sibling,as:UTF8.self)]
        let combined=try await repo.history(options:history)
        XCTAssertEqual(combined.map(\.hash),[c3,c2,c1])
        history.paths=[]
        let snapshot=try await repo.blame(path:newKey,revision:c3)
        XCTAssertEqual(snapshot.contents,changed);XCTAssertEqual(snapshot.path,newKey)
        XCTAssertEqual(snapshot.lines.first?.sourceBytes,Data("first annotation\r".utf8))
        XCTAssertEqual(snapshot.lines.map(\.hash),[c1,c3,c1,c1]);XCTAssertEqual(snapshot.lines.map(\.filename),[oldKey,newKey,oldKey,oldKey])
        XCTAssertTrue(snapshot.lines[0].displayFilename.contains("FF"))
        var blameOptions=GitBlameOptions();blameOptions.followRenames=true
        let blameHistory=try await repo.blameHistory(snapshot,options:blameOptions)
        XCTAssertEqual(blameHistory.map(\.hash),[c3,c2,c1])
        blameOptions.showCompleteLog=false
        let attributed=try await repo.blameHistory(snapshot,options:blameOptions)
        XCTAssertEqual(Set(attributed.map(\.hash)),Set([c3,c1]))
        // Mailmap and ordinary walk/search flags operate on the same captured
        // commits; an opaque path must not select a reduced metadata query.
        try Data("Mapped Author <mapped@example.invalid> Patch Tests <patch@example.invalid>\n".utf8).write(to:root.appendingPathComponent(".mailmap"))
        history.path=newKey;history.walk.followRenames=true;history.search="edit raw"
        let filtered=try await repo.history(options:history)
        XCTAssertEqual(filtered.map(\.hash),[c3]);XCTAssertEqual(filtered.first?.author,"Mapped Author")
        history.useMailmap=false;history.walk.firstParent=true;history.walk.noMerges=true
        let unmapped=try await repo.history(options:history)
        XCTAssertEqual(unmapped.first?.author,"Patch Tests")
        blameOptions.showCompleteLog=true;blameOptions.useMailmap=false
        let rawIdentities=try await repo.blameHistory(snapshot,options:blameOptions)
        XCTAssertTrue(rawIdentities.allSatisfy{$0.author=="Patch Tests"})
        blameOptions.useMailmap=true
        let mappedIdentities=try await repo.blameHistory(snapshot,options:blameOptions)
        XCTAssertTrue(mappedIdentities.allSatisfy{$0.author=="Mapped Author"})
        var annotationOptions=GitBlameOptions();annotationOptions.onlyFirstParent=true;annotationOptions.ignoreWhitespace=true;annotationOptions.detectionMode = .withinFile
        let annotated=try await repo.blame(path:newKey,revision:c3,options:annotationOptions)
        XCTAssertEqual(annotated.contents,changed);XCTAssertEqual(annotated.lines.map(\.sourceBytes),snapshot.lines.map(\.sourceBytes))
        let copyPath=Data([0xfd])+Data(" copied.txt".utf8),copyKey=try RepositoryBrowserGitPath(rawData:Data([0xfd])+Data(" copied.txt".utf8)).key
        let copyTree=try await tree(repo,[(new,changedBlob),(sibling,otherBlob),(copyPath,changedBlob)])
        let copyCommit=try await commit(repo,copyTree,parent:c3,message:"copy raw origin")
        var copyOptions=GitBlameOptions();copyOptions.detectionMode = .existingFiles;copyOptions.betweenFileCharacters=1
        let copied=try await repo.blame(path:copyKey,revision:copyCommit,options:copyOptions)
        XCTAssertEqual(copied.contents,changed)
        XCTAssertEqual(copied.lines.map(\.filename),snapshot.lines.map(\.filename))
        XCTAssertEqual(copied.lines.map(\.hash),snapshot.lines.map(\.hash))
        let parentChoices=try await repo.blameParentComparisons(revision:c3,path:newKey)
        XCTAssertEqual(parentChoices.map(\.revision),[c2]);XCTAssertEqual(parentChoices.map(\.path),[newKey])
        do {_ = try await repo.historicalFile(revision:c3,path:newKey);XCTFail("Raw filename entered ordinary materialization")} catch is WorkingFileRestoreFailure {}
        let source=try await repo.blame(path:oldKey,revision:c1)
        XCTAssertEqual(source.contents,original)
        let entry=try XCTUnwrap(followed.first{$0.hash==c2})
        for backend in [GitLibGit2Configuration(mask:0),GitLibGit2Configuration(mask:1<<15)] {
            let reader=GitRepository(root:root,executable:repo.executable,askpass:nil,libgit2Configuration:backend)
            let files=try await reader.files(in:entry,backend:backend)
            let rename=try XCTUnwrap(files.first{$0.action.hasPrefix("R")})
            XCTAssertEqual(rename.path,newKey);XCTAssertEqual(rename.oldPath,oldKey);XCTAssertFalse(rename.isPathRepresentable)
            XCTAssertEqual(try RepositoryBrowserGitPath(key:rename.path).rawData,new)
            let changes=try await reader.revisionChanges(in:[entry]);XCTAssertEqual(changes[entry.hash]?.first?.path,newKey)
            let simple=try await reader.historyDiff(revision:c2,simple:true,backend:backend.requests(.logListDiff) ? backend : .init(mask:1<<15),cancellation:nil)
            XCTAssertTrue(simple.paths.contains(newKey));XCTAssertTrue(simple.paths.contains(oldKey))
        }
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.blame(path:newKey,revision:c3,cancellation:token);XCTFail("Cancelled raw blame succeeded")} catch is OperationCancellationFailure {}
        do {_ = try await repo.history(options:history,cancellation:token);XCTFail("Cancelled raw history succeeded")} catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(workingPath)),work)
    }

    func testRawDirectoryScopeUsesTreeNamespaceAndRejectsFileOnlyFollow()async throws {
        let(root,initial,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root,executable:initial.executable,askpass:nil,libgit2Configuration:.init(mask:0))
        let directory=Data([0xff])+Data(" folder".utf8),key=try RepositoryBrowserGitPath(rawData:Data([0xff])+Data(" folder".utf8)).key
        let a=try await blob(repo,Data("base child\n".utf8)),b=try await blob(repo,Data("changed child\n".utf8))
        let firstChild=try await tree(repo,[(Data("child.txt".utf8),a)]),secondChild=try await tree(repo,[(Data("child.txt".utf8),b)])
        func parentTree(_ child:String)async throws->String {
            var wire=Data("040000 tree \(child)\t".utf8);wire.append(directory);wire.append(0)
            return try await repo.run(["mktree","-z"],input:wire).text.trimmingCharacters(in:.newlines)
        }
        let t1=try await parentTree(firstChild),t2=try await parentTree(secondChild)
        let c1=try await commit(repo,t1,parent:nil,message:"raw folder birth"),c2=try await commit(repo,t2,parent:c1,message:"raw folder child change")
        var options=HistoryOptions();options.path=key;options.endRevision=c2;options.limit = -1
        let entries=try await repo.history(options:options)
        XCTAssertEqual(entries.map(\.hash),[c2,c1])
        let scopes=try await repo.historyPathScopes(paths:[key],revision:c2)
        XCTAssertEqual(scopes.count,1);XCTAssertTrue(try XCTUnwrap(scopes.first).isDirectory)
        let canFollow=try await repo.canFollowHistory(paths:[key],revision:c2);XCTAssertFalse(canFollow)
        let files=try await repo.files(in:try XCTUnwrap(entries.first),backend:.init(mask:0))
        let child=try XCTUnwrap(files.first)
        XCTAssertEqual(try RepositoryBrowserGitPath(key:child.path).rawData,directory+Data("/child.txt".utf8))
        XCTAssertTrue(try XCTUnwrap(scopes.first).contains(child))
        options.walk.followRenames=true
        do {_ = try await repo.history(options:options);XCTFail("Folder accepted file-only follow")} catch is HistoryWalkFailure {}
    }

    func testNameStatusStatisticsAndQuotedOriginsPreserveRawIdentity()throws {
        let raw=Data([0xff])+Data(".txt".utf8),replacement=Data("\u{fffd}.txt".utf8)
        var names=Data(),stats=Data()
        for (i,path) in [raw,replacement].enumerated() {names.append(Data("M\0".utf8));names.append(path);names.append(0);stats.append(Data("\(i+1)\t0\t".utf8));stats.append(path);stats.append(0)}
        let files=CommitFile.parse(names:names,statistics:stats)
        XCTAssertEqual(files.count,2);XCTAssertNotEqual(files[0].path,files[1].path)
        XCTAssertEqual(files.map(\.added),[1,2]);XCTAssertFalse(files[0].displayPath.contains("\0"))
        XCTAssertEqual(try RepositoryBrowserGitPath(key:GitBlameParser.filename("\"\\377.txt\"")).rawData,raw)
        XCTAssertThrowsError(try GitBlameParser.filename("\"\\000.txt\""))
        let directory=try RepositoryBrowserGitPath(rawData:Data([0xff])).key
        let child=try RepositoryBrowserGitPath(rawData:Data([0xff,47,65])).key
        let file=CommitFile(path:child,oldPath:nil,action:"M",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)
        XCTAssertTrue(HistoryPathScope(path:directory,isDirectory:true).contains(file))
        XCTAssertFalse(HistoryPathScope(path:"\u{fffd}",isDirectory:true).contains(file))
        XCTAssertFalse(StatusListClipboard.displayedPath(files[0]).contains("\0"))
        XCTAssertEqual(StatusListClipboard.fileExtension(files[0].path),".txt")
    }
    func testHelperProtocolAcceptsOnlyValidatedOpaqueNamespaceKeys()throws {
        let oid=String(repeating:"a",count:40),old=String(repeating:"b",count:40)
        func frame(_ object:[String:Any])throws->Data {GitHistoryDiffDecoder.prefix+(try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)).base64EncodedData()+Data([10])}
        let key=try RepositoryBrowserGitPath(rawData:Data([0xff,47,65])).key
        for path in [key,"\0arbitrary","\0TurtleGitBrowserPath:"+Data("valid".utf8).base64EncodedString(),"\0TurtleGitBrowserPath:"+Data([0xff,47,46,46]).base64EncodedString()] {
            let decoder=GitHistoryDiffDecoder(revision:oid,simple:true)
            let wire=try frame(["kind":"header","revision":oid,"parents":[old]])+frame(["kind":"path","path":path])+frame(["kind":"end","count":1])
            if path==key {try decoder.append(wire);XCTAssertEqual(try decoder.finish().paths,[key])}
            else {XCTAssertThrowsError(try decoder.append(wire))}
        }
    }

}
