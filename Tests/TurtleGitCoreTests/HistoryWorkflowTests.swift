import XCTest
@testable import TurtleGitCore

final class HistoryWorkflowTests:XCTestCase {
    final class OutputCapture:@unchecked Sendable {
        let lock=NSLock();var bytes=Data()
        func append(_ chunk:GitOutputChunk) { lock.lock();defer { lock.unlock() };bytes.append(chunk.data) }
        var text:String { lock.lock();defer { lock.unlock() };return String(decoding:bytes,as:UTF8.self) }
    }
    func fixture() async throws -> (URL,GitRepository,[LogEntry]) {
        let (root,repo,_)=try await GitPatchTests().fixture()
        for name in ["a","b","c"] { try Data((name+"\n").utf8).write(to:root.appendingPathComponent(name));try await repo.stage([name]);_ = try await repo.commit(message:"add "+name) }
        return (root,repo,try await repo.history())
    }
    func testCombineStreamsResetAndReplayPreservesFinalTreeAndBranch() async throws {
        let (root,repo,entries)=try await fixture();defer { try? FileManager.default.removeItem(at:root) }
        let tree=try await repo.run(["rev-parse","HEAD^{tree}"]).stdout
        let plan=try await repo.prepareHistoryCombine(hashes:entries[1...2].map(\.hash),firstOffset:1,expectedHead:entries[0].hash)
        let reset=OutputCapture();let resetText=try await repo.beginHistoryCombine(plan,onOutput:reset.append);XCTAssertEqual(reset.text,resetText)
        try await repo.verifyHistoryCombineAmend(plan)
        _ = try await repo.run(["commit","--amend","-m",plan.message])
        let replay=OutputCapture();let replayText=try await repo.finishHistoryCombine(plan,onOutput:replay.append);XCTAssertEqual(replay.text,replayText);XCTAssertFalse(replayText.isEmpty)
        let finalTree=try await repo.run(["rev-parse","HEAD^{tree}"]).stdout, branch=try await repo.branch(), rows=try await repo.history()
        XCTAssertEqual(finalTree,tree);XCTAssertEqual(branch,"main");XCTAssertEqual(rows.count,entries.count-1);let combinedMessage=try await repo.run(["show","-s","--format=%B",rows[1].hash]).text;XCTAssertTrue(combinedMessage.contains("add a"));XCTAssertTrue(combinedMessage.contains("add b"))
    }
    func testCombineSelectionValidatesInteriorRowsWithoutRequiringCleanTree() async throws {
        let (root,repo,entries)=try await fixture();defer { try? FileManager.default.removeItem(at:root) }
        let branch=try await repo.validateHistoryCombineSelection(hashes:entries.prefix(3).map(\.hash),firstOffset:0,expectedHead:entries[0].hash);XCTAssertEqual(branch,"refs/heads/main")
        var corrupt=entries.prefix(3).map(\.hash);corrupt[1]=entries[3].hash
        do { _ = try await repo.validateHistoryCombineSelection(hashes:corrupt,firstOffset:0,expectedHead:entries[0].hash);XCTFail("Invalid middle row accepted") } catch HistoryCombineFailure.selection {}
        try Data("dirty\n".utf8).write(to:root.appendingPathComponent("a"))
        _ = try await repo.validateHistoryCombineSelection(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:entries[0].hash)
        do { _ = try await repo.prepareHistoryCombine(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:entries[0].hash);XCTFail("Dirty preparation accepted") } catch HistoryCombineFailure.dirty {}
        do { _ = try await repo.validateHistoryCombineSelection(hashes:entries.prefix(2).map(\.hash),firstOffset:0,expectedHead:entries[1].hash);XCTFail("Moving HEAD accepted") } catch HistoryCombineFailure.changed {}
    }
    func testCancelledCombineBetweenResetsRestoresOriginalTreeAndHead() async throws {
        let (root,repo,entries)=try await fixture();defer { try? FileManager.default.removeItem(at:root) }
        let tree=try await repo.run(["rev-parse","HEAD^{tree}"]).stdout
        let plan=try await repo.prepareHistoryCombine(hashes:entries[1...2].map(\.hash),firstOffset:1,expectedHead:entries[0].hash)
        let wrapper=root.appendingPathComponent("combine-git"),marker=root.appendingPathComponent("ready")
        let script="#!/bin/sh\nif [ \"$4\" = reset ] && [ \"$5\" = --soft ];then echo $$ > \"$3/ready\";/bin/sleep 30;fi\nexec /usr/bin/git \"$@\"\n"
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let wrapped=GitRepository(root:root,executable:wrapper),token=OperationCancellation(),output=OutputCapture()
        let task=Task { try await wrapped.beginHistoryCombine(plan,cancellation:token,onOutput:output.append) }
        for _ in 0..<500 { if FileManager.default.fileExists(atPath:marker.path) { break };try await Task.sleep(nanoseconds:10_000_000) }
        let ready=FileManager.default.fileExists(atPath:marker.path);token.cancel()
        do { _ = try await task.value;XCTFail("Cancelled Combine succeeded") } catch is GitCommandCancellationFailure {} catch is OperationCancellationFailure {}
        XCTAssertTrue(ready)
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),indexTree=try await repo.run(["write-tree"]).stdout,diff=try await repo.run(["diff","--"]).stdout
        XCTAssertEqual(head,entries[0].hash);XCTAssertEqual(indexTree,tree);XCTAssertTrue(diff.isEmpty);XCTAssertTrue(output.text.contains(entries[0].subject))
    }
    func testRevertOutputStreamDoesNotCommitOrLeakPreflightMetadata() async throws {
        let (root,repo,entries)=try await fixture();defer { try? FileManager.default.removeItem(at:root) }
        let output=OutputCapture();let result=try await repo.revertLogRevision(revision:entries[0].hash,onOutput:output.append)
        XCTAssertEqual(output.text,result.text)
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(head,entries[0].hash);XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("c").path))
    }
}
