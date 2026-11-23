import XCTest
@testable import TurtleGitCore

final class StatusListFileComparisonTests:XCTestCase {
    private func fixture(_ files:[String:String]=["anchor":"base\n"],commit:Bool=true) async throws -> (URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-status-operands-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=GitRepository(root:root,libgit2Configuration:.init(enabled:false))
        do {
            _ = try await repository.run(["init","-b","main"])
            for (key,value) in [("user.name","Operand Tests"),("user.email","operands@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {
                _ = try await repository.run(["config",key,value])
            }
            for (path,text) in files {try Data(text.utf8).write(to:root.appendingPathComponent(path))}
            try await repository.stage(Array(files.keys))
            if commit {_ = try await repository.commit(message:"base")}
            return (root,repository)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private func entry(_ path:String,_ xy:String,old:String?=nil)->StatusEntry {
        let codes=Array(xy)
        return StatusEntry(path:path,originalPath:old,index:codes[0],worktree:codes[1])
    }
    private func index(_ root:URL)throws->Data {try Data(contentsOf:root.appendingPathComponent(".git/index"))}
    private func comparison(_ repo:GitRepository,_ row:StatusEntry,_ base:ComparisonRevision = .revision("HEAD"),submodule:Bool=false) async throws -> RevisionComparisonSnapshot {
        try await repo.statusListFileComparison(.init(entry:row,base:base,isSubmodule:submodule))
    }

    func testAcceptedAddedBeforeDeletedAndDeletedIgnoresRecreatedDisk() async throws {
        let (root,repo)=try await fixture(["old":"historical\n"])
        defer{try? FileManager.default.removeItem(at:root)}
        let new="new 雪\n[?].txt"
        try Data("staged\n".utf8).write(to:root.appendingPathComponent(new));try await repo.stage([new])
        try FileManager.default.removeItem(at:root.appendingPathComponent(new))
        let status=try await repo.status(refreshIndex:false)
        let accepted=try XCTUnwrap(status.first{$0.path==new})
        XCTAssertEqual(String([accepted.index,accepted.worktree]),"AD")
        try Data("recreated\n".utf8).write(to:root.appendingPathComponent(new))
        _ = try await repo.run(["rm","--","old"])
        try Data("replacement must not be compared\n".utf8).write(to:root.appendingPathComponent("old"))
        let before=try index(root)
        let added=try await comparison(repo,accepted)
        XCTAssertEqual(added.from,.emptyTree);XCTAssertEqual(added.to,.workingTree);XCTAssertEqual(added.files.first?.action,"A")
        let addContent=try await repo.comparisonFile(added,path:new)
        XCTAssertTrue(addContent.base.bytes.isEmpty);XCTAssertEqual(addContent.destination.bytes,Data("recreated\n".utf8))
        let deleted=try await comparison(repo,entry("old","D "))
        XCTAssertEqual(deleted.to,.emptyTree);XCTAssertEqual(deleted.files.first?.action,"D")
        let delContent=try await repo.comparisonFile(deleted,path:"old")
        XCTAssertEqual(delContent.base.bytes,Data("historical\n".utf8));XCTAssertTrue(delContent.destination.bytes.isEmpty)
        XCTAssertEqual(try index(root),before)
    }

    func testRootAndAmendOperandsUseAcceptedBaseRatherThanCurrentHead() async throws {
        let (unborn,initial)=try await fixture(["first":"initial\n"],commit:false)
        defer{try? FileManager.default.removeItem(at:unborn)}
        let first=try await comparison(initial,entry("first","A "),.emptyTree)
        XCTAssertEqual(first.from,.emptyTree)
        let initialContent=try await initial.comparisonFile(first,path:"first")
        XCTAssertTrue(initialContent.base.bytes.isEmpty);XCTAssertEqual(initialContent.destination.bytes,Data("initial\n".utf8))
        let (root,repo)=try await fixture(["file":"parent\n"])
        defer{try? FileManager.default.removeItem(at:root)}
        try Data("head\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"second")
        try Data("working\n".utf8).write(to:root.appendingPathComponent("file"))
        let before=try index(root)
        for (base,expected) in [("HEAD~1","parent\n"),("HEAD","head\n")] {
            let snapshot=try await comparison(repo,entry("file"," M"),.revision(base))
            let content=try await repo.comparisonFile(snapshot,path:"file")
            XCTAssertEqual(content.base.bytes,Data(expected.utf8));XCTAssertEqual(content.destination.bytes,Data("working\n".utf8))
        }
        let rootNull=try await comparison(repo,entry("file"," M"),.emptyTree)
        XCTAssertEqual(rootNull.files.first?.action,"A");XCTAssertEqual(rootNull.from,.emptyTree)
        XCTAssertEqual(try index(root),before)
    }

    func testPartiallyStagedAddedDoesNotBecomeFreshRename() async throws {
        let original=(0..<80).map{"original source line \($0)\n"}.joined()
        let (root,repo)=try await fixture(["old":original])
        defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["rm","--","old"])
        try Data("unrelated staged addition\n".utf8).write(to:root.appendingPathComponent("new"));try await repo.stage(["new"])
        try Data(original.utf8).write(to:root.appendingPathComponent("new"))
        let rows=try await repo.status(refreshIndex:false)
        let row=try XCTUnwrap(rows.first{$0.path=="new"})
        XCTAssertEqual(row.index,"A");XCTAssertEqual(row.worktree,"M")
        let fresh=try await repo.revisionFileComparison(from:.revision("HEAD"),to:.workingTree,paths:["new"])
        XCTAssertEqual(fresh.files.first?.action,"R");XCTAssertEqual(fresh.files.first?.oldPath,"old")
        let before=try index(root)
        let snapshot=try await comparison(repo,row)
        XCTAssertEqual(snapshot.files.first?.action,"A");XCTAssertNil(snapshot.files.first?.oldPath);XCTAssertEqual(snapshot.from,.emptyTree)
        let content=try await repo.comparisonFile(snapshot,path:"new")
        XCTAssertTrue(content.base.bytes.isEmpty);XCTAssertEqual(content.destination.bytes,Data(original.utf8))
        XCTAssertEqual(try index(root),before)
    }

    func testRenameAndControlledCopyKeepLiteralAcceptedOrigin() async throws {
        let old="-old 雪\n[abc]",other="different source",destination="destination\n?.txt"
        let original=(0..<80).map{"accepted origin \($0)\n"}.joined(),replacement=(0..<80).map{"other origin \($0)\n"}.joined()
        let (root,repo)=try await fixture([old:original,other:replacement])
        defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["mv","--",old,destination])
        try Data(replacement.utf8).write(to:root.appendingPathComponent(destination))
        let rows=try await repo.status(refreshIndex:false)
        let renamed=try XCTUnwrap(rows.first{$0.path==destination})
        XCTAssertEqual(renamed.index,"R");XCTAssertEqual(renamed.originalPath,old)
        let before=try index(root)
        // C is an explicitly supplied accepted metadata projection, not a claim
        // that this fixture's porcelain invocation naturally detects copies.
        for row in [renamed,entry(destination,"CM",old:old)] {
            let snapshot=try await comparison(repo,row)
            XCTAssertEqual(snapshot.files.first?.oldPath,old)
            XCTAssertEqual(snapshot.files.first?.action,String(row.index))
            let content=try await repo.comparisonFile(snapshot,path:destination)
            XCTAssertEqual(content.base.path,old);XCTAssertEqual(content.base.bytes,Data(original.utf8))
            XCTAssertEqual(content.destination.bytes,Data(replacement.utf8))
        }
        XCTAssertEqual(try index(root),before)
    }

    func testRequiredHistoricalOperandInvalidBaseAndCancellationRefuse() async throws {
        let (root,repo)=try await fixture()
        defer{try? FileManager.default.removeItem(at:root)}
        try Data("local\n".utf8).write(to:root.appendingPathComponent("new"))
        let before=try index(root)
        for row in [entry("new"," M"),entry("new","R ",old:"absent"),entry("new","C ")] {
            do {_ = try await comparison(repo,row);XCTFail("Missing required operand accepted")}
            catch is RevisionComparisonFailure {}
        }
        do {_ = try await comparison(repo,entry("new","A "),.workingTree);XCTFail("Working base accepted")}
        catch RevisionComparisonFailure.range {}
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.statusListFileComparison(.init(entry:entry("new","A "),base:.emptyTree,isSubmodule:false),cancellation:token);XCTFail("Cancelled read ran")}
        catch is OperationCancellationFailure {}
        XCTAssertEqual(try index(root),before)
    }

    func testSymlinkReadsTargetTextAndDeletedSideRemainsAbsent() async throws {
        let (root,repo)=try await fixture()
        defer{try? FileManager.default.removeItem(at:root)}
        let path="link",url=root.appendingPathComponent(path)
        try FileManager.default.createSymbolicLink(atPath:url.path,withDestinationPath:"original-target")
        try await repo.stage([path]);_ = try await repo.commit(message:"link")
        try FileManager.default.removeItem(at:url)
        try FileManager.default.createSymbolicLink(atPath:url.path,withDestinationPath:"../nonexistent-target\n")
        let before=try index(root)
        let snapshot=try await comparison(repo,entry(path," M"))
        let content=try await repo.comparisonFile(snapshot,path:path)
        XCTAssertEqual(content.base.mode,"120000");XCTAssertEqual(content.destination.mode,"120000")
        XCTAssertEqual(content.base.bytes,Data("original-target".utf8));XCTAssertEqual(content.destination.bytes,Data("../nonexistent-target\n".utf8))
        let deleted=try await comparison(repo,entry(path,"D "))
        let deletedContent=try await repo.comparisonFile(deleted,path:path)
        XCTAssertTrue(deletedContent.destination.bytes.isEmpty);XCTAssertEqual(deletedContent.base.bytes,content.base.bytes)
        XCTAssertEqual(try index(root),before)
    }

    func testPorcelainConflictLettersDoNotInventRawAddedDeletedActions() async throws {
        // These controlled stage receipts exercise every porcelain conflict
        // label. StartDiff consumes raw diff-index U, not the letters in XY.
        let cases:[(String,[Int])]=[("DD",[1]),("AU",[2]),("UA",[3]),("UD",[1,2]),("DU",[1,3]),("AA",[2,3]),("UU",[1,2,3])]
        let (root,repo)=try await fixture(Dictionary(uniqueKeysWithValues:cases.map{($0.0,"historical \($0.0)\n")}))
        defer{try? FileManager.default.removeItem(at:root)}
        let blob=try await repo.run(["rev-parse","HEAD:UU"]).text.trimmingCharacters(in:.newlines)
        var packet=Data()
        for (code,stages) in cases {
            packet.append(Data("0 \(String(repeating:"0",count:blob.count))\t\(code)\u{0}".utf8))
            for stage in stages {packet.append(Data("100644 \(blob) \(stage)\t\(code)\u{0}".utf8))}
            try Data("working \(code)\n".utf8).write(to:root.appendingPathComponent(code))
        }
        _ = try await repo.run(["update-index","-z","--index-info"],input:packet)
        let rows=try await repo.status(refreshIndex:false)
        let raw=try await repo.run(["diff-index","--cached","--raw","-z","HEAD","--"]).stdout.split(separator:0)
        let rawHeaders=raw.filter{$0.first==58}.map{String(decoding:$0,as:UTF8.self)}
        XCTAssertEqual(rawHeaders.count,cases.count);XCTAssertTrue(rawHeaders.allSatisfy{$0.hasSuffix(" U")})
        let before=try index(root)
        for (code,_) in cases {
            let row=try XCTUnwrap(rows.first{$0.path==code})
            XCTAssertEqual(String([row.index,row.worktree]),code)
            let snapshot=try await comparison(repo,row)
            XCTAssertEqual(snapshot.files.first?.action,"M");XCTAssertNotEqual(snapshot.from,.emptyTree);XCTAssertEqual(snapshot.to,.workingTree)
            let content=try await repo.comparisonFile(snapshot,path:code)
            XCTAssertEqual(content.base.bytes,Data("historical \(code)\n".utf8))
            XCTAssertEqual(content.destination.bytes,Data("working \(code)\n".utf8))
        }
        XCTAssertEqual(try index(root),before)
    }

    func testGitlinkNullSidesDoNotRequireCheckoutAndOrdinaryDirectoryRefuses() async throws {
        let (root,repo)=try await fixture()
        defer{try? FileManager.default.removeItem(at:root)}
        let oid=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","--add","--cacheinfo","160000,"+oid+",module"])
        let before=try index(root)
        let added=try await comparison(repo,entry("module","A "),submodule:true)
        XCTAssertEqual(added.from,.emptyTree);XCTAssertTrue(try XCTUnwrap(added.files.first).isSubmodule)
        XCTAssertEqual(try index(root),before)
        _ = try await repo.commit(message:"gitlink")
        _ = try await repo.run(["update-index","--force-remove","--","module"])
        try Data("replacement regular file".utf8).write(to:root.appendingPathComponent("module"))
        let deletedBefore=try index(root)
        let deleted=try await comparison(repo,entry("module","D "))
        XCTAssertEqual(deleted.to,.emptyTree);XCTAssertTrue(try XCTUnwrap(deleted.files.first).isSubmodule)
        XCTAssertEqual(try index(root),deletedBefore)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("directory"),withIntermediateDirectories:true)
        for isSubmodule in [false,true] {
            do {_ = try await comparison(repo,entry("directory","A "),submodule:isSubmodule);XCTFail("Unversioned directory accepted as blob/gitlink")}
            catch {}
        }
    }
}
