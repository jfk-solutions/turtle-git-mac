import XCTest
@testable import TurtleGitCore

final class FinderWorktreeValidationTests:XCTestCase {
    private func fixture()async throws->(URL,GitRepository) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("FinderWorktreeValidation-"+UUID().uuidString),root=folder.appendingPathComponent("source 雪.git")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=GitRepository(root:root,executable:URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_QA_GIT"] ?? "/usr/bin/git"))
        _ = try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Worktree validation"),("user.email","validation@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
        try Data("original\n".utf8).write(to:root.appendingPathComponent("tracked"));try await repository.stage(["tracked"]);_ = try await repository.commit(message:"baseline")
        return(folder,repository)
    }
    func testOnlyActualWorkingAndBareRootsAreSourcesWithoutMutation()async throws {
        let (folder,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"])
        let validRoot=try await repo.validateFinderWorktreeSource()
        XCTAssertEqual(validRoot.resolvingSymlinksInPath(),repo.root.resolvingSymlinksInPath())
        let nested=repo.root.appendingPathComponent("nested");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:false)
        let metadataAlias=folder.appendingPathComponent("metadata-alias")
        try FileManager.default.createSymbolicLink(at:metadataAlias,withDestinationURL:repo.root.appendingPathComponent(".git"))
        for invalid in [nested,metadataAlias,repo.root.appendingPathComponent("tracked"),repo.root.appendingPathComponent(".git"),repo.root.appendingPathComponent("missing"),folder,URL(fileURLWithPath:"/")] {
            do {_ = try await GitRepository(root:invalid,executable:repo.executable).validateFinderWorktreeSource();XCTFail("Accepted non-root source \(invalid.path)")} catch {}
        }
        let bare=folder.appendingPathComponent("bare.git"),bareRepo=GitRepository(root:bare,executable:repo.executable)
        try FileManager.default.createDirectory(at:bare,withIntermediateDirectories:false);_ = try await bareRepo.run(["init","--bare"])
        let validBare=try await bareRepo.validateFinderWorktreeSource()
        XCTAssertEqual(validBare.resolvingSymlinksInPath(),bare.resolvingSymlinksInPath())
        let afterHead=try await repo.run(["rev-parse","HEAD"])
        XCTAssertEqual(afterHead.stdout,head.stdout);XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),index)
        let trees=try await repo.worktrees();XCTAssertEqual(trees.count,1)
    }
    func testDestinationUsesUnversionedParentAndRefusesWorkingTreeAliasesAndAdmin()async throws {
        let (folder,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let parent=folder.appendingPathComponent("chosen parent"),nested=repo.root.appendingPathComponent("nested"),alias=folder.appendingPathComponent("alias")
        for directory in [parent,nested] {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)}
        try Data("unrelated\n".utf8).write(to:parent.appendingPathComponent("keep"))
        let destination=try await repo.finderWorktreeDestination(parent:parent)
        XCTAssertEqual(destination.lastPathComponent,"source 雪");XCTAssertEqual(destination.deletingLastPathComponent().resolvingSymlinksInPath(),parent.resolvingSymlinksInPath())
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path));XCTAssertEqual(try Data(contentsOf:parent.appendingPathComponent("keep")),Data("unrelated\n".utf8))
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:nested)
        let metadataAlias=folder.appendingPathComponent("admin-alias")
        try FileManager.default.createSymbolicLink(at:metadataAlias,withDestinationURL:repo.root.appendingPathComponent(".git"))
        let broken=folder.appendingPathComponent("broken-checkout"),marker=Data(("gitdir: "+folder.appendingPathComponent("missing-git-directory").path+"\n").utf8)
        try FileManager.default.createDirectory(at:broken,withIntermediateDirectories:false)
        try marker.write(to:broken.appendingPathComponent(".git"))
        for invalid in [repo.root,nested,alias,metadataAlias,broken,repo.root.appendingPathComponent(".git"),repo.root.appendingPathComponent("tracked"),folder.appendingPathComponent("missing")] {
            do {_ = try await repo.finderWorktreeDestination(parent:invalid);XCTFail("Accepted versioned/non-directory destination \(invalid.path)")} catch {}
        }
        // Corrupt Git metadata may report GitFailure rather than the normal
        // Finder destination error; either must refuse without repairing it.
        XCTAssertEqual(try Data(contentsOf:broken.appendingPathComponent(".git")),marker)
        let bareParent=folder.appendingPathComponent("bare-parent.git")
        try FileManager.default.createDirectory(at:bareParent,withIntermediateDirectories:false)
        _ = try await GitRepository(root:bareParent,executable:repo.executable).run(["init","--bare"])
        let bareDestination=try await repo.finderWorktreeDestination(parent:bareParent)
        XCTAssertEqual(bareDestination.lastPathComponent,"source 雪");XCTAssertFalse(FileManager.default.fileExists(atPath:bareDestination.path))
        let trees=try await repo.worktrees();XCTAssertEqual(trees.count,1)
    }
    func testCancelledSourceAndDestinationValidationCannotCreateAnything()async throws {
        let (folder,repo)=try await fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let parent=folder.appendingPathComponent("cancelled");try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false)
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.validateFinderWorktreeSource(cancellation:token);XCTFail("Accepted cancelled source validation")} catch OperationCancellationFailure.cancelled {}
        do {_ = try await repo.finderWorktreeDestination(parent:parent,cancellation:token);XCTFail("Accepted cancelled destination validation")} catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:parent.path),[]);let trees=try await repo.worktrees();XCTAssertEqual(trees.count,1)
    }
}
