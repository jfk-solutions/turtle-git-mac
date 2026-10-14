import XCTest
@testable import TurtleGitCore

final class HistoryMetadataBatchTests:XCTestCase {
    func testStreamingLogRecordsPreserveEveryUTF8SplitAndEmptyField() throws {
        let hash = String(repeating: "a", count: 40), other = String(repeating: "b", count: 64)
        let fields = [hash, "", "Author 雪", "", "2026-10-14T12:00:00Z", "Subject 🦎", "Subject 🦎\n\nBody é\n", "Committer", "mail@example.invalid", "2026-10-14T13:00:00Z", "-"]
        let second = [other, hash, "", "", "", "", "", "", "", "", ""]
        let bytes = Data((fields.joined(separator: "\0") + "\0\n" + second.joined(separator: "\0") + "\0\n").utf8)
        for split in 0...bytes.count {
            let parser = HistoryRecordStream(); parser.ingest(Data(bytes.prefix(split))); parser.ingest(Data(bytes.dropFirst(split)))
            let records = try parser.finish()
            XCTAssertEqual(records.map(\.hash), [hash, other]); XCTAssertEqual(records[0].author, fields[2]); XCTAssertEqual(records[0].message, fields[6]); XCTAssertTrue(records[0].isBoundary)
            XCTAssertEqual(records[1].parents, [hash]); XCTAssertEqual(records[1].email, "")
        }
        let truncated = HistoryRecordStream(); truncated.ingest(Data(bytes.dropLast(4))); XCTAssertThrowsError(try truncated.finish())
        let invalid = HistoryRecordStream(); invalid.ingest(Data(("bad\0" + fields.dropFirst().joined(separator: "\0") + "\0").utf8)); XCTAssertThrowsError(try invalid.finish())
    }
    func testStreamingFramingBufferDoesNotGrowWithWalkLength() throws {
        let fields = [String(repeating: "c", count: 40), "", "Author", "", "", "subject", String(repeating: "雪", count: 1024), "", "", "", ""]
        let record = Data((fields.joined(separator: "\0") + "\0\n").utf8), parser = HistoryRecordStream()
        for _ in 0..<200 { for start in stride(from: 0, to: record.count, by: 7) { parser.ingest(Data(record[start..<min(start + 7, record.count)])) } }
        XCTAssertEqual(try parser.finish().count, 200)
        XCTAssertLessThanOrEqual(parser.maximumBufferedBytes, record.count)
    }

    func fixture() async throws -> (URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMetadata-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Metadata QA"),("user.email","metadata@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        return (root,repo)
    }
    func testLengthFramingPreservesNULUTF8AndFakeProtocolTextAndRejectsTruncation() throws {
        let hash=String(repeating:"a",count:40),note="Before\0雪\nlog size 999\nAfter\n"
        let payload=Data((hash+"\0"+note).utf8),raw=Data("log size \(payload.count)\n".utf8)+payload+Data("\n".utf8)
        XCTAssertEqual(try HistoryMetadataProtocol.sizedLog(raw)[hash],note.trimmingCharacters(in:.newlines))
        XCTAssertThrowsError(try HistoryMetadataProtocol.sizedLog(Data(raw.dropLast(3))))
        let object=Data("object x\n\n\0tag bytes 雪\n".utf8)
        let batch=Data("\(hash) tag \(object.count)\n".utf8)+object+Data("\n".utf8)
        XCTAssertEqual(try HistoryMetadataProtocol.objects(batch,expected:[hash],type:"tag")[hash],object)
        XCTAssertThrowsError(try HistoryMetadataProtocol.objects(Data(batch.dropLast()),expected:[hash],type:"tag"))
        XCTAssertThrowsError(try HistoryMetadataProtocol.objects(batch,expected:[hash],type:"blob"))
    }
    func testChangesParserDoesNotConfuseHashNamedFilesWithCommitHeaders() throws {
        let hash=String(repeating:"a",count:40),next=String(repeating:"b",count:40)
        let raw=Data((hash+"\0A\0"+next+"\0R100\0old\npath\0new\tpath\0"+next+"\0D\0file\0").utf8)
        let result=try HistoryMetadataProtocol.changes(raw,expected:[hash,next])
        XCTAssertEqual(result[hash]?.count,2);XCTAssertEqual(result[hash]?.first?.path,next)
        XCTAssertEqual(result[hash]?.last?.oldPath,"old\npath");XCTAssertEqual(result[hash]?.last?.path,"new\tpath")
        XCTAssertThrowsError(try HistoryMetadataProtocol.changes(Data((hash+"\0R100\0only-one-path\0").utf8),expected:[hash]))
    }
    func testEmptyRootAndEmptyCommitKeepHeadersAndIndependentActions() async throws {
        let (root,repo)=try await fixture();defer { try? FileManager.default.removeItem(at:root) }
        for message in ["root","empty"] { _ = try await repo.run(["commit","--allow-empty","-m",message]) }
        let entries=try await repo.history(),result=try await repo.revisionChanges(in:entries)
        XCTAssertEqual(result.count,2);XCTAssertTrue(result.values.allSatisfy(\.isEmpty))
        let actions=try await repo.revisionActions(in:entries);XCTAssertTrue(actions.values.allSatisfy(\.isEmpty))
    }
    func testBatchedPathsAndActionsMatchEveryParentWithoutChangingRepository() async throws {
        let (root,repo)=try await fixture();defer { try? FileManager.default.removeItem(at:root) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("base"));try await repo.stage(["base"]);_ = try await repo.commit(message:"base")
        _ = try await repo.run(["checkout","-b","side"])
        try Data("side\n".utf8).write(to:root.appendingPathComponent("side\n雪"));try await repo.stage(["side\n雪"]);_ = try await repo.commit(message:"side")
        _ = try await repo.run(["checkout","main"])
        try FileManager.default.moveItem(at:root.appendingPathComponent("base"),to:root.appendingPathComponent("renamed\tbase"))
        try await repo.stage(["base","renamed\tbase"]);_ = try await repo.commit(message:"rename")
        _ = try await repo.run(["merge","--no-ff","side","-m","merge"])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let entries=try await repo.history(),batched=try await repo.revisionChanges(in:entries)
        for entry in entries {
            var expected:[CommitFile]=[]
            for parent in entry.parents.isEmpty ? [nil] : entry.parents.map(Optional.some) {
                var args=["diff-tree","--root","--no-commit-id","--name-status","-z","-r","-M","--no-ext-diff","--no-color"]
                if let parent { args.append(parent) };args += [entry.hash,"--"]
                expected += CommitFile.parse(names:try await repo.run(args).stdout,statistics:Data())
            }
            XCTAssertEqual(batched[entry.hash]?.map { $0.action+"\0"+($0.oldPath ?? "")+"\0"+$0.path },expected.map { $0.action+"\0"+($0.oldPath ?? "")+"\0"+$0.path })
        }
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(afterHead,head);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testLargeNotesAndTagBatchesPreserveDisplayedTextAndBoundCommandCount() async throws {
        let (root,repo)=try await fixture();defer { try? FileManager.default.removeItem(at:root) }
        let tree=try await repo.run(["mktree"],input:Data()).text.trimmingCharacters(in:.newlines)
        var hashes:[String]=[]
        for index in 0..<130 {
            var args=["commit-tree",tree];if let parent=hashes.last { args += ["-p",parent] }
            hashes.append(try await repo.run(args,input:Data("row \(index)\n".utf8)).text.trimmingCharacters(in:.newlines))
        }
        _ = try await repo.run(["update-ref","refs/heads/main",hashes.last!])
        let note=Data("Before\0AfterMarker 雪\nlog size 123\n".utf8)
        let blob=try await repo.run(["hash-object","-w","--stdin"],input:note).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["notes","add","-C",blob,hashes[0]])
        _ = try await repo.run(["tag","-a","tag-one","-m","annotation 雪",hashes[0]])
        let wrapper=root.appendingPathComponent("count-git")
        try """
        #!/bin/sh
        printf '%s\\n' "$4" >> "$0.calls"
        exec /usr/bin/git "$@"

        """.write(to:wrapper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let measured=GitRepository(root:root,executable:wrapper)
        var options=HistoryOptions();options.limit = -1;options.searchFields = .notes;options.search="AfterMarker"
        let result=try await measured.history(options:options)
        XCTAssertEqual(result.map(\.hash),[hashes[0]])
        let displayed=try await repo.run(["show","--no-patch","--notes","--format=%N",hashes[0],"--"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(result.first?.notes,displayed);XCTAssertTrue(result.first?.tagInfo.contains("annotation 雪")==true)
        let commands=try String(contentsOf:URL(fileURLWithPath:wrapper.path+".calls")).split(separator:"\n")
        // Two notes batches plus two actual-parent batches, not 130 note processes.
        XCTAssertEqual(commands.filter { $0=="show" }.count,4)
        XCTAssertEqual(commands.filter { $0=="cat-file" }.count,1)
        let token=OperationCancellation();token.cancel()
        do { _ = try await repo.revisionChanges(in:result,cancellation:token);XCTFail("Cancelled metadata") } catch OperationCancellationFailure.cancelled {}
    }
}
