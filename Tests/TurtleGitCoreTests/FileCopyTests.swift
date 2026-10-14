import XCTest
@testable import TurtleGitCore
final class FileCopyTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, URL) {
        let (root, repo) = try await CommitSelectionTests().fixture()
        let source = root.deletingLastPathComponent().appendingPathComponent("CopySource-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return (root, repo, source)
    }
    func testLiteralCopyStagesWorkingBytesWithoutChangingOriginalIndexOrHead() async throws {
        let (root,repo,external) = try await fixture(); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
        let name = "-雪\n[*].txt", source = external.appendingPathComponent(name)
        try Data("copy\n".utf8).write(to:source)
        let plan = try await repo.prepareFileCopy(source:source,to:root)
        _ = try await repo.copyWorkingItem(plan,overwrite:false); _ = try await repo.stageCopiedItem(plan.destination,ignoredRepositories:[])
        let data = try await repo.run(["show",":"+name]).text
        XCTAssertEqual(data,"copy\n"); XCTAssertEqual(try String(contentsOf:source),"copy\n")
        let head = try await repo.run(["rev-parse","--quiet","--verify","HEAD"],successfulExitCodes:0...1).stdout; XCTAssertTrue(head.isEmpty)
    }
    func testOverwritePlanRevalidatesDestinationAndSourceTree() async throws {
        let (root,repo,external) = try await fixture(); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
        let source = external.appendingPathComponent("file"), target = root.appendingPathComponent("file")
        try Data("copy".utf8).write(to:source);try Data("keep".utf8).write(to:target)
        let plan = try await repo.prepareFileCopy(source:source,to:root); XCTAssertTrue(plan.occupied)
        do { _ = try await repo.copyWorkingItem(plan,overwrite:false); XCTFail("Overwrote without choice") } catch FileMoveFailure.occupied {}
        try Data("changed".utf8).write(to:target,options:.atomic)
        do { _ = try await repo.copyWorkingItem(plan,overwrite:true); XCTFail("Overwrote changed target") } catch FileMoveFailure.changed {}
        let fresh = try await repo.prepareFileCopy(source:source,to:root); _ = try await repo.copyWorkingItem(fresh,overwrite:true)
        XCTAssertEqual(try String(contentsOf:target),"copy")
        try FileManager.default.createDirectory(at:external.appendingPathComponent("dir/deep"),withIntermediateDirectories:true)
        let child=external.appendingPathComponent("dir/deep/child");try Data("one".utf8).write(to:child)
        let tree=try await repo.prepareFileCopy(source:external.appendingPathComponent("dir"),to:root);try Data("changed child".utf8).write(to:child)
        do {_ = try await repo.copyWorkingItem(tree,overwrite:false);XCTFail("Copied changed descendant")}catch FileMoveFailure.changed{}
    }
    func testDirectoryCopyNestedMetadataDeleteAndIgnoreNeverModifySource() async throws {
        let (root,repo,external)=try await fixture();defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:external)}
        let folder=external.appendingPathComponent("tree"), nested=folder.appendingPathComponent("nested"), ignored=folder.appendingPathComponent("ignored")
        for url in [nested,ignored] {try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);_ = try await GitRepository(root:url).run(["init"]);try Data("inside".utf8).write(to:url.appendingPathComponent("file"))}
        try Data("plain".utf8).write(to:folder.appendingPathComponent("plain"));try FileManager.default.createSymbolicLink(at:folder.appendingPathComponent("link"),withDestinationURL:external.appendingPathComponent("missing"))
        let plan=try await repo.prepareFileCopy(source:folder,to:root),copied=try await repo.copyWorkingItem(plan,overwrite:false)
        XCTAssertEqual(copied.repositories.map(\.path),["tree/ignored","tree/nested"])
        try await repo.removeCopiedGitMetadata(copied.repositories[1]);_ = try await repo.stageCopiedItem("tree",ignoredRepositories:["tree/ignored"])
        let indexed=try await repo.run(["ls-files","-z"]).stdout
        XCTAssertTrue(indexed.range(of: Data("tree/nested/file".utf8)) != nil);XCTAssertNil(indexed.range(of: Data("tree/ignored/file".utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath:nested.appendingPathComponent(".git").path));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("tree/nested/.git").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:root.appendingPathComponent("tree/link").path),external.appendingPathComponent("missing").path)
    }
    func testCopiedSubmoduleMetadataAndUnreviewedRepositoryCannotBeStaged() async throws {
        let (root,repo,external)=try await fixture();defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:external)}
        let folder=external.appendingPathComponent("module");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("gitdir: ../original/.git/modules/test\n".utf8).write(to:folder.appendingPathComponent(".git"));try Data("file".utf8).write(to:folder.appendingPathComponent("file"))
        let plan=try await repo.prepareFileCopy(source:folder,to:root),result=try await repo.copyWorkingItem(plan,overwrite:false)
        XCTAssertTrue(result.repositories[0].gitFile)
        do {_ = try await repo.stageCopiedItem(result.destination,ignoredRepositories:[]);XCTFail("Staged unreviewed metadata")}catch FileMoveFailure.changed{}
        try await repo.removeCopiedGitMetadata(result.repositories[0]);_ = try await repo.stageCopiedItem(result.destination,ignoredRepositories:[])
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.appendingPathComponent(".git").path))
    }
    func testWrongTargetsSelfCopyAndCancelledCopyDoNotMutate() async throws {
        let (root,repo,external)=try await fixture();defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:external)}
        let source=external.appendingPathComponent("file");try Data("copy".utf8).write(to:source)
        for target in [external,root.appendingPathComponent(".git")] {do {_ = try await repo.prepareFileCopy(source:source,to:target);XCTFail("Accepted outside/admin target")}catch FileMoveFailure.destination{}}
        let plan=try await repo.prepareFileCopy(source:source,to:root),token=OperationCancellation();token.cancel()
        do {_ = try await repo.copyWorkingItem(plan,overwrite:false,cancellation:token);XCTFail("Cancelled copy executed")}catch OperationCancellationFailure.cancelled{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("file").path))
        try Data("same".utf8).write(to:root.appendingPathComponent("file"))
        do {_ = try await repo.prepareFileCopy(source:root.appendingPathComponent("file"),to:root);XCTFail("Self copy accepted")}catch FileMoveFailure.unchanged{}
    }
    func testClipboardMoveRetainsOrderRejectsUnversionedAndOtherRepositories() async throws {
        let (root,repo,external)=try await fixture();defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:external)}
        for name in ["b","a"] {try Data(name.utf8).write(to:root.appendingPathComponent(name))};try await repo.stage(["b","a"])
        let paths=try await repo.clipboardMovePaths([root.appendingPathComponent("b"),root.appendingPathComponent("a"),root.appendingPathComponent("b")]);XCTAssertEqual(paths,["b","a"])
        do {_ = try await repo.clipboardMovePaths([external.appendingPathComponent("file")]);XCTFail("Other working tree accepted")}catch FileMoveFailure.destination{}
        try Data("u".utf8).write(to:root.appendingPathComponent("untracked"))
        do {_ = try await repo.clipboardMovePaths([root.appendingPathComponent("untracked")]);XCTFail("Untracked move accepted")}catch FileMoveFailure.selection{}
    }
}
