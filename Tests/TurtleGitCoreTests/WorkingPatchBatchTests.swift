import XCTest
@testable import TurtleGitCore

final class WorkingPatchBatchTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository, WorkingTreePatchReview) {
        let (root, repository, _) = try await GitPatchTests().fixture()
        for path in ["a 雪.txt", "middle.txt", "z.txt"] { try Data("before\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repository.stage(["a 雪.txt", "middle.txt", "z.txt"]); _ = try await repository.commit(message: "patch files")
        for path in ["a 雪.txt", "middle.txt", "z.txt"] { try Data("after\n".utf8).write(to: root.appendingPathComponent(path)) }
        let bytes = try await repository.run(["diff", "--binary", "--"]).stdout
        for path in ["a 雪.txt", "z.txt"] { try Data("before\n".utf8).write(to: root.appendingPathComponent(path)) }
        try Data("conflicting\n".utf8).write(to: root.appendingPathComponent("middle.txt"))
        return (root, repository, try await repository.reviewWorkingTreePatch(bytes))
    }
    func testOrderedBatchContinuesAfterConflictWithoutChangingIndexOrHead() async throws {
        let (root, repository, review) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(review.canApply)
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let result = try await repository.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id)))
        XCTAssertFalse(result.cancelled); XCTAssertEqual(result.files.map { String(decoding: $0.pathBytes, as: UTF8.self) }, ["a 雪.txt", "middle.txt", "z.txt"])
        XCTAssertEqual(result.files.map(\.success), [true,false,true]); XCTAssertTrue(result.files[1].output.contains("middle.txt"))
        for path in ["a 雪.txt", "z.txt"] { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path)), "after\n") }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("middle.txt")), "conflicting\n")
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(head, afterHead); XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index")))
    }
    func testCancellationRetainsCompletedFileAndStopsBeforeTheNext() async throws {
        let (root, repository, review) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = OperationCancellation()
        let result = try await repository.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id)), cancellation: token) { _ in token.cancel() }
        XCTAssertTrue(result.cancelled); XCTAssertEqual(result.files.count, 1); XCTAssertTrue(result.files[0].success)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("z.txt")), "before\n")
    }
    func testInvalidSelectionAndForeignReviewAreRefusedBeforeMutation() async throws {
        let (root, repository, review) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repository.applyWorkingTreePatchBatch(review, fileIDs: [999]); XCTFail("Invalid selection accepted") } catch WorkingTreePatchFailure.review {}
        let foreign = GitRepository(root: root.appendingPathComponent("foreign"))
        do { _ = try await foreign.applyWorkingTreePatchBatch(review, fileIDs: Set(review.files.map(\.id))); XCTFail("Foreign review accepted") } catch WorkingTreePatchFailure.review {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a 雪.txt")), "before\n")
    }
}

extension WorkingPatchBatchTests {
    private var mergeEngine:SubversionMergeConfiguration {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return .init(executable:root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"),runtimeRoot:root.appendingPathComponent("build/git-runtime/Git"))
    }
    private func recoveryFixture(current:String,reverse:Bool=false,recordBase:Bool=true) async throws -> (URL,GitRepository,WorkingTreePatchReview) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_TEST_GIT"] ?? "/usr/bin/git"))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Recovery QA"),("user.email","recovery@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        let file=root.appendingPathComponent("file.txt")
        try Data("head\nold\nkeep\ntail\n".utf8).write(to:file)
        try await repo.stage(["file.txt"]);_=try await repo.commit(message:"base")
        try Data("head\nnew\nkeep\ntail\n".utf8).write(to:file)
        var patch=try await repo.run(["diff","--full-index","--"]).stdout
        _=try await repo.run(["hash-object","-w","--","file.txt"])
        if !recordBase {patch=Data(String(decoding:patch,as:UTF8.self).components(separatedBy:"\n").filter{!$0.hasPrefix("index ")}.joined(separator:"\n").utf8)}
        try Data(current.utf8).write(to:file)
        return (root,repo,try await repo.reviewWorkingTreePatch(patch,reversed:reverse))
    }
    func testRecordedBaseRecoveryPreviewsConflictAndSavesOnlyChosenBytes() async throws {
        let current="head\nlocal 🐢\nkeep\ntail\n"
        let (root,repo,review)=try await recoveryFixture(current:current);defer{try? FileManager.default.removeItem(at:root)}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        XCTAssertFalse(review.canApply)
        let inspections=try await repo.inspectWorkingTreePatchFiles(review)
        XCTAssertEqual(inspections[Data("file.txt".utf8)]?.state,.conflict)
        let comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id)
        XCTAssertEqual(comparison.recoveryBase?.text,"head\nold\nkeep\ntail\n")
        XCTAssertEqual(comparison.document.base.text,current)
        XCTAssertEqual(comparison.document.destination.text,"head\nnew\nkeep\ntail\n")
        let document=try comparison.patchMergeDocument(engine:mergeEngine)
        XCTAssertEqual(document.mine,current);XCTAssertEqual(document.theirs,comparison.document.destination.text)
        XCTAssertEqual(MergeText.conflicts(in:document.initialResult,document:document).count,1)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file.txt")),current)
        let resolved=try MergeText.applying(.theirs,block:0,to:document.initialResult,document:document)
        let saved=try await repo.saveWorkingTreePatchFile(comparison,text:resolved,autoAddNewFiles:false)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file.txt")),"head\nnew\nkeep\ntail\n")
        XCTAssertEqual(try document.recordingPatchSave(saved).initialResult,resolved)
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(afterHead,head)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testCleanThreeWayBatchRetainsIndependentContextEditWithoutIndexChanges() async throws {
        let current="head\nold\nkeep\nlocal tail\n"
        let (root,repo,review)=try await recoveryFixture(current:current);defer{try? FileManager.default.removeItem(at:root)}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let batch=try await repo.applyWorkingTreePatchBatch(review,fileIDs:[review.files[0].id],mergeConfiguration:mergeEngine)
        XCTAssertEqual(batch.files.map(\.success),[true])
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file.txt")),"head\nnew\nkeep\nlocal tail\n")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testReverseRecoveryUsesNewBlobAndPreservesIndependentEdit() async throws {
        let (root,repo,review)=try await recoveryFixture(current:"head\nnew\nkeep\nlocal tail\n",reverse:true);defer{try? FileManager.default.removeItem(at:root)}
        let comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id)
        XCTAssertEqual(comparison.recoveryBase?.text,"head\nnew\nkeep\ntail\n")
        let merged=try comparison.patchMergeDocument(engine:mergeEngine)
        XCTAssertEqual(merged.initialResult,"head\nold\nkeep\nlocal tail\n")
    }
    func testConflictBatchDoesNotWriteMarkersAndStaleRecoverySaveRefusesChanges() async throws {
        let current="head\nlocal\nkeep\ntail\n"
        let (root,repo,review)=try await recoveryFixture(current:current);defer{try? FileManager.default.removeItem(at:root)}
        let comparison=try await repo.compareWorkingTreePatchFile(review,fileID:review.files[0].id)
        let batch=try await repo.applyWorkingTreePatchBatch(review,fileIDs:[review.files[0].id],mergeConfiguration:mergeEngine)
        XCTAssertTrue(batch.files[0].requiresMerge);XCTAssertFalse(batch.files[0].success)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file.txt")),current)
        try Data("external edit\n".utf8).write(to:root.appendingPathComponent("file.txt"))
        do {_=try await repo.saveWorkingTreePatchFile(comparison,text:"resolved\n");XCTFail("Stale recovery overwrote working file")} catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file.txt")),"external edit\n")
    }
    func testMissingBaseMetadataIsAnInitialErrorAndCancelledInspectionDoesNotRun() async throws {
        let current="head\nlocal\nkeep\ntail\n"
        let (root,repo,review)=try await recoveryFixture(current:current,recordBase:false);defer{try? FileManager.default.removeItem(at:root)}
        let inspections=try await repo.inspectWorkingTreePatchFiles(review)
        XCTAssertEqual(inspections[Data("file.txt".utf8)]?.state,.error)
        XCTAssertFalse(inspections[Data("file.txt".utf8)]?.diagnostic.isEmpty ?? true)
        let cancelled=OperationCancellation();cancelled.cancel()
        do {_=try await repo.inspectWorkingTreePatchFiles(review,cancellation:cancelled);XCTFail("Cancelled inspection ran")} catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file.txt")),current)
    }
}

extension WorkingPatchBatchTests {
    func testRecordedBaseRenameRecoveryKeepsLiteralPathsModeAndOriginalIndex() async throws {
        let (root,repo,bytes)=try await WorkingTreePatchReviewTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("one\nlocal two\nthree\nfour\n".utf8).write(to:root.appendingPathComponent("--old 雪"))
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let review=try await repo.reviewWorkingTreePatch(bytes),file=try XCTUnwrap(review.files.first{$0.path=="--new 雪"})
        let comparison=try await repo.compareWorkingTreePatchFile(review,fileID:file.id)
        XCTAssertTrue(comparison.requiresMerge);XCTAssertEqual(comparison.recoveryBase?.text,"one\ntwo\nthree\nfour\n")
        let document=try comparison.patchMergeDocument(engine:mergeEngine)
        let resolved=try MergeText.applying(.theirs,block:0,to:document.initialResult,document:document)
        _=try await repo.saveWorkingTreePatchFile(comparison,text:resolved,autoAddNewFiles:false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("--old 雪").path))
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("--new 雪")),"one\ntwo changed\nthree\nfour\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("--new 雪").path)[.posixPermissions] as! NSNumber).intValue & 0o111,0o111)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testIgnoredRecoveryConflictsStillRequireExplicitReviewBeforeWriting() async throws {
        let current="head\nn e w\nkeep\ntail\n"
        let (root,repo,review)=try await recoveryFixture(current:current);defer{try? FileManager.default.removeItem(at:root)}
        var engine=mergeEngine;engine.options.whitespace = .ignoreAll
        let batch=try await repo.applyWorkingTreePatchBatch(review,fileIDs:[review.files[0].id],mergeConfiguration:engine)
        XCTAssertTrue(batch.files[0].requiresMerge);XCTAssertFalse(batch.files[0].success)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("file.txt")),current)
    }
}
