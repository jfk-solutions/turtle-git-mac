import XCTest
@testable import TurtleGitCore

final class FileMoveTests: XCTestCase {
    func fixture() async throws -> (URL,GitRepository,String,URL) {
        let (root,repo)=try await CommitSelectionTests().fixture(),path="src/-file 雪\n[*].txt",destination=root.appendingPathComponent("target 雪",isDirectory:true)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("src"),withIntermediateDirectories:true);try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        try Data("base\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"base")
        try Data("staged\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);try Data("working\n".utf8).write(to:root.appendingPathComponent(path))
        return (root,repo,path,destination)
    }
    func testMovePreservesIndependentIndexAndWorkingContentsAndDoesNotCommit() async throws {
        let (root,repo,path,destination)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        let plan=try await repo.prepareFileMove(source:path,to:destination);_ = try await repo.executeFileMove(plan)
        let index=try await repo.run(["show",":"+plan.destination]).text,after=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(index,"staged\n");XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(plan.destination)),"working\n");XCTAssertEqual(head,after)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path))
    }
    func testDirectoryMoveKeepsTrackedAndUntrackedContentsAndSymbolicLinkIdentity() async throws {
        let (root,repo,path,destination)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        try Data("untracked\n".utf8).write(to:root.appendingPathComponent("src/local"))
        let folder=try await repo.prepareFileMove(source:"src",to:destination);_ = try await repo.executeFileMove(folder)
        XCTAssertEqual(try String(contentsOf:destination.appendingPathComponent("src/local")),"untracked\n")
        let index=try await repo.run(["show",":"+folder.destination+"/"+(path as NSString).lastPathComponent]).text;XCTAssertEqual(index,"staged\n")
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:root.appendingPathComponent("missing"));try await repo.stage(["link"])
        let link=try await repo.prepareFileMove(source:"link",to:destination);_ = try await repo.executeFileMove(link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:destination.appendingPathComponent("link").path),root.appendingPathComponent("missing").path)
        let mode=try await repo.run(["ls-files","--stage","--",link.destination]).text;XCTAssertTrue(mode.hasPrefix("120000 "))
    }
    func testOccupiedDestinationAndChangedPlanDoNotOverwrite() async throws {
        let (root,repo,path,destination)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let existing=destination.appendingPathComponent((path as NSString).lastPathComponent);try Data("keep\n".utf8).write(to:existing)
        do {_ = try await repo.prepareFileMove(source:path,to:destination);XCTFail("Accepted occupied name")}catch FileMoveFailure.occupied{}
        let plan=try await repo.prepareFileMove(source:path,to:destination,name:"renamed.txt")
        try Data("new staged\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path])
        do {_ = try await repo.executeFileMove(plan);XCTFail("Accepted changed index")}catch FileMoveFailure.changed{}
        XCTAssertEqual(try String(contentsOf:existing),"keep\n");XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(plan.destination).path))
    }
    func testWorkingReplacementAndHeadChangeInvalidatePreparedMove() async throws {
        let (root,repo,path,destination)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let plan=try await repo.prepareFileMove(source:path,to:destination);try Data("external\n".utf8).write(to:root.appendingPathComponent(path),options:.atomic)
        do {_ = try await repo.executeFileMove(plan);XCTFail("Moved replaced workfile")}catch FileMoveFailure.changed{}
        let fresh=try await repo.prepareFileMove(source:path,to:destination);_ = try await repo.run(["commit","--allow-empty","-m","new head"])
        do {_ = try await repo.executeFileMove(fresh);XCTFail("Moved under changed HEAD")}catch FileMoveFailure.changed{}
    }
    func testAdminNestedAndEscapingTargetsAndSelfDescendantRejectBeforeMutation() async throws {
        let (root,repo,path,destination)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let outside=root.deletingLastPathComponent().appendingPathComponent("FileMoveOutside-"+UUID().uuidString);try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:outside)}
        let alias=root.appendingPathComponent("escape");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:outside)
        let nested=root.appendingPathComponent("nested");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true);_ = try await GitRepository(root:nested).run(["init"])
        for folder in [root.appendingPathComponent(".git"),alias,nested,outside] {do {_ = try await repo.prepareFileMove(source:path,to:folder);XCTFail("Accepted wrong destination")}catch FileMoveFailure.destination{}}
        do {_ = try await repo.prepareFileMove(source:"src",to:root.appendingPathComponent("src"));XCTFail("Moved directory into itself")}catch FileMoveFailure.destination{}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),token=OperationCancellation();token.cancel()
        do {_ = try await repo.prepareFileMove(source:path,to:destination,cancellation:token);XCTFail("Cancelled preparation accepted")}catch OperationCancellationFailure.cancelled{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testCaseOnlyMoveAndCancelledExecutionKeepLiteralNamesAndWorkingData() async throws {
        let (root,repo)=try await CommitSelectionTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        try Data("staged\n".utf8).write(to:root.appendingPathComponent("name.txt"));try await repo.stage(["name.txt"]);_ = try await repo.commit(message:"base")
        try Data("working\n".utf8).write(to:root.appendingPathComponent("name.txt"))
        let plan=try await repo.prepareFileMove(source:"name.txt",to:root,name:"NAME.txt"),token=OperationCancellation();token.cancel()
        do {_ = try await repo.executeFileMove(plan,cancellation:token);XCTFail("Cancelled move executed")}catch OperationCancellationFailure.cancelled{}
        _ = try await repo.executeFileMove(plan)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("NAME.txt")),"working\n")
        let index=try await repo.run(["show",":NAME.txt"]).text;XCTAssertEqual(index,"staged\n")
    }
}
