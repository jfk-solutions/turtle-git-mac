import XCTest
@testable import TurtleGitCore

final class StashOperationTests: XCTestCase {
    func testUserSaveRechecksIdentityBeforeChangingIndexWorktreeOrStash() async throws {
        let (root,repo,path)=try await GitPatchTests().fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        try Data("dirty\n".utf8).write(to:root.appendingPathComponent(path))
        var options=StashSaveOptions();options.requireIdentity=true
        for key in ["user.name","user.email","author.name","author.email","committer.name","committer.email"] {_ = try await repo.run(["config",key,""])}
        let identity=try await repo.replayUserIdentity()
        guard !identity.complete else {throw XCTSkip("Process explicitly supplies the source identity overrides")}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        do {_ = try await repo.saveStash(options);XCTFail("Captured user Save accepted missing identity")}catch StashFailure.identity {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(path),encoding:.utf8),"dirty\n")
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(finalHead,head)
        let stash=try await repo.run(["show-ref","--verify","--quiet","refs/stash"],successfulExitCodes:0...1)
        XCTAssertEqual(stash.exitCode,1)
    }
    func testInternalCleanSaveRetainsGitSemanticsAndCancellationCannotMutate() async throws {
        let (root,repo,path)=try await GitPatchTests().fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        for key in ["user.name","user.email","author.name","author.email","committer.name","committer.email"] {_ = try await repo.run(["config",key,""])}
        let result=try await repo.saveStash(StashSaveOptions())
        XCTAssertFalse(result.created)
        try Data("cancelled\n".utf8).write(to:root.appendingPathComponent(path))
        let token=OperationCancellation();token.cancel()
        var options=StashSaveOptions();options.requireIdentity=true
        do {_ = try await repo.saveStash(options,cancellation:token);XCTFail("Cancelled user save ran")}catch is OperationCancellationFailure {}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(path),encoding:.utf8),"cancelled\n")
    }
}
