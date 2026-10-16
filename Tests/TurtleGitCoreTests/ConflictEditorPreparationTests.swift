import XCTest
@testable import TurtleGitCore

final class ConflictEditorPreparationTests: XCTestCase {
    func testPreCancelledExternalAndTextPreparationLeaveConflictUntouched() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let input = try await repo.externalMergeInputs(path:path), index = try Data(contentsOf:root.appendingPathComponent(".git/index")), file = try Data(contentsOf:root.appendingPathComponent(path))
        let token = OperationCancellation();token.cancel()
        let operations: [() async throws -> Void] = [
            { _ = try await repo.externalMergeInputs(path:path,cancellation:token) },
            { _ = try await repo.conflictEditorEntry(path:path,cancellation:token) },
            { try await repo.validateExternalMergeInputs(input,cancellation:token) },
            { _ = try await repo.textConflictDocument(path:path,cancellation:token) }
        ]
        for operation in operations { do { try await operation();XCTFail("Cancelled preparation accepted") } catch OperationCancellationFailure.cancelled {} }
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),file)
        _ = try await repo.resolveConflicts([input.entry],using:.mine)
        let resolved=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        do { try await repo.validateExternalMergeInputs(input);XCTFail("Prepared tool inputs survived changed stages") } catch ResolveFailure.stale {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),resolved)
    }
    func testPreCancelledImageReadsSelectionsAndMarkResolvedPreserveIndexAndWorkingBytes() async throws {
        let (root,repo,_) = try await ImageConflictTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let value = try await repo.imageConflictDocument(path:"picture.png"),document = try XCTUnwrap(value)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),file=try Data(contentsOf:root.appendingPathComponent("picture.png")),token=OperationCancellation();token.cancel()
        let operations: [() async throws -> Void] = [
            { _ = try await repo.imageConflictDocument(path:"picture.png",cancellation:token) },
            { _ = try await repo.selectImageConflict(document,side:.theirs,cancellation:token) },
            { _ = try await repo.markImageConflictResolved(document,cancellation:token) }
        ]
        for operation in operations { do { try await operation();XCTFail("Cancelled image operation accepted") } catch OperationCancellationFailure.cancelled {} }
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("picture.png")),file)
    }
    func testExternalStageReadCancellationStopsOwnedGitBeforePreparingInputs() async throws {
        let (root,repo,path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),file=try Data(contentsOf:root.appendingPathComponent(path)),helper=root.appendingPathComponent("gated-git"),marker=root.appendingPathComponent("ready")
        let script = #"""
        #!/bin/sh
        if [ "$4" = cat-file ] && [ "$5" = blob ];then
          : > "$3/ready"
          while :; do /bin/sleep 0.05; done
        fi
        exec /usr/bin/git "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let wrapped=GitRepository(root:root,executable:helper),token=OperationCancellation()
        let read=Task { try await wrapped.externalMergeInputs(path:path,cancellation:token) }
        defer { token.cancel() }
        for _ in 0..<1000 { if FileManager.default.fileExists(atPath:marker.path) { break };try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path));token.cancel()
        do { _ = try await read.value;XCTFail("Cancelled stage read returned tool inputs") }
        catch is GitCommandCancellationFailure {} catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),file)
    }
}
