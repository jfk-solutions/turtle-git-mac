import XCTest
@testable import TurtleGitCore
final class RenameWorkflowTests:XCTestCase {
    func testCapturedRenameRefusesReplacedWorkfileAndPrecancellation()async throws{
        let (root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let plan=try await repo.prepareRename(RenameOptions(source:path,name:"new"));try Data("replacement".utf8).write(to:root.appendingPathComponent(path),options:.atomic)
        do{_ = try await repo.executeRename(plan);XCTFail("Renamed changed source")}catch RenameFailure.changed{}
        let next=try await repo.prepareRename(RenameOptions(source:path,name:"new")),token=OperationCancellation();token.cancel()
        do{_ = try await repo.executeRename(next,cancellation:token);XCTFail("Cancelled rename ran")}catch OperationCancellationFailure.cancelled{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("new").path))
    }
    func testBrowseDestinationKeepsRelativeParentComponentsAndDoesNotWrite()async throws{
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root.appendingPathComponent("folder"),withIntermediateDirectories:true)
        let result=try await repo.renameDestination(root.appendingPathComponent("target 雪\n.txt"),source:"folder/source")
        XCTAssertEqual(result,"../target 雪\n.txt");XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("target 雪\n.txt").path))
    }
    func testReferenceRenameRefusesCapturedHashThatChanged()async throws{
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["branch","topic"]);let before=try await repo.run(["rev-parse","topic"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["commit","--allow-empty","-m","another"]);_ = try await repo.run(["branch","-f","topic","HEAD"])
        do{try await repo.renameBrowserBranch("refs/heads/topic",folder:"refs/heads",label:"renamed",expectedHash:before);XCTFail("Renamed changed branch")}catch ReferenceBrowserRenameFailure.changed{}
        let refs=try await repo.run(["for-each-ref","--format=%(refname)"]).text;XCTAssertTrue(refs.contains("refs/heads/topic"));XCTAssertFalse(refs.contains("refs/heads/renamed"))
    }
    func testReferenceMutationsRefuseChangedTipAndPreserveConfig() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "topic"])
        try await repo.updateBranchDescription("topic", message: "keep description")
        _ = try await repo.run(["config", "branch.topic.remote", "origin"])
        _ = try await repo.run(["config", "branch.topic.merge", "refs/heads/main"])
        let hash = try await repo.run(["rev-parse", "topic"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["commit", "--allow-empty", "-m", "advanced"])
        _ = try await repo.run(["branch", "-f", "topic", "HEAD"])
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        do { try await repo.updateBranchDescription("topic", message: "overwrite", expectedHash: hash); XCTFail("Changed description") } catch ReferenceBrowserRenameFailure.changed {}
        do { try await repo.updateBrowserTracking("refs/heads/topic", upstream: nil, expectedHash: hash); XCTFail("Changed tracking") } catch ReferenceBrowserRenameFailure.changed {}
        do { try await repo.deleteBrowserReferences(["refs/heads/topic"], expectedHashes: ["refs/heads/topic": hash]); XCTFail("Deleted changed tip") } catch ReferenceBrowserRenameFailure.changed {}
        XCTAssertEqual(config, try Data(contentsOf: root.appendingPathComponent(".git/config")))
        let exists = try await repo.run(["rev-parse", "--verify", "refs/heads/topic"]).exitCode
        XCTAssertEqual(exists, 0)
    }
}
