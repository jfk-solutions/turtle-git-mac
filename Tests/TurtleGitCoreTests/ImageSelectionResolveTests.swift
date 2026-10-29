// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class ImageSelectionResolveTests:XCTestCase {
    func testBinarySelectionResolvesCapturedStagesPreservingWorkingBytesAndPeerIndex()async throws {
        let (root,repository,path)=try await ConflictResolutionTests().fixture()
        defer{try? FileManager.default.removeItem(at:root)}
        let conflicts=try await repository.conflicts(paths:[path])
        let entry=try XCTUnwrap(conflicts.first)
        let peer="peer-🐢.bin",peerURL=root.appendingPathComponent(peer)
        try Data([1,0,255,17]).write(to:peerURL)
        _ = try await repository.run(["add","--",peer])
        let before=try await repository.run(["ls-files","--stage","-z","--",peer]).stdout
        let bytes=Data([0xff,0,0x89,0x50,0x4e,0x47,0,1,2,3,0xfe]),file=root.appendingPathComponent(path)
        let saved=try MergeToolOutputTarget(capturing:file).save(bytes:bytes)
        XCTAssertNil(saved.content.text,"The actual selected output must exercise the binary route")
        try await repository.resolveSelectedImageOutput(saved,expectedConflict:entry)
        let indexed=try await repository.run(["show",":"+path]).stdout
        let after=try await repository.run(["ls-files","--stage","-z","--",peer]).stdout
        XCTAssertEqual(indexed,bytes);XCTAssertEqual(after,before);XCTAssertEqual(try Data(contentsOf:file),bytes)
        let remaining=try await repository.conflicts(paths:[path]);XCTAssertTrue(remaining.isEmpty)
    }
    func testStaleConflictStagesAndCanceledAttemptNeverPublishOrRewriteSavedOutput()async throws {
        let (root,repository,path)=try await ConflictResolutionTests().fixture()
        defer{try? FileManager.default.removeItem(at:root)}
        let conflicts=try await repository.conflicts(paths:[path])
        let entry=try XCTUnwrap(conflicts.first)
        let bytes=Data([0,255,0,128]),file=root.appendingPathComponent(path)
        let saved=try MergeToolOutputTarget(capturing:file).save(bytes:bytes)
        _ = try await repository.run(["add","--",path])
        let index=try await repository.run(["ls-files","--stage","-z"]).stdout
        do {try await repository.resolveSelectedImageOutput(saved,expectedConflict:entry);XCTFail("Resolved a different captured index state")}
        catch ResolveFailure.stale {}
        let unchanged=try await repository.run(["ls-files","--stage","-z"]).stdout
        XCTAssertEqual(unchanged,index);XCTAssertEqual(try Data(contentsOf:file),bytes)
        let token=OperationCancellation();token.cancel()
        do {try await repository.resolveSelectedImageOutput(saved,expectedConflict:entry,cancellation:token);XCTFail("Canceled image resolution published")}
        catch OperationCancellationFailure.cancelled {}
        let canceledIndex=try await repository.run(["ls-files","--stage","-z"]).stdout
        XCTAssertEqual(canceledIndex,index);XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
}
