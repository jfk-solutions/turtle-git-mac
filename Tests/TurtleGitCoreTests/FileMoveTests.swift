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
    private func installExact(_ path:String, text:String, repo:GitRepository) async throws {
        let hash = try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","-z","--index-info"],input:Data("100644 \(hash)\t\(path)\0".utf8))
    }
    func testNormalizationOnlyRenameThenMoveKeepExactIndexAndSeparateWorkingBytes() async throws {
        let (root,repo) = try await CommitSelectionTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        let a = "café.txt", b = "cafe\u{301}.txt"
        _ = try await repo.run(["config","core.precomposeunicode","true"])
        try Data("working\n".utf8).write(to:root.appendingPathComponent(b))
        try await installExact(b,text:"staged\n",repo:repo);_ = try await repo.commit(message:"base")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        let renamed = try await repo.prepareRename(.init(source:b,name:a));_ = try await repo.executeRename(renamed)
        XCTAssertTrue(GitReferenceName.equal(renamed.destination,a))
        let observedTransfer1 = try await repo.run(["-c","core.precomposeunicode=false","ls-files","-z"]).stdout
        XCTAssertEqual(observedTransfer1,Data((a+"\0").utf8))
        let folder = root.appendingPathComponent("target");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let moved = try await repo.prepareFileMove(source:a,to:folder);_ = try await repo.executeFileMove(moved)
        let observedTransfer2 = try await repo.run(["-c","core.precomposeunicode=false","ls-files","-z"]).stdout
        XCTAssertEqual(observedTransfer2,Data(("target/"+a+"\0").utf8))
        let observedTransfer3 = try await repo.run(["-c","core.precomposeunicode=false","show",":target/"+a]).stdout
        XCTAssertEqual(observedTransfer3,Data("staged\n".utf8))
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(a)),Data("working\n".utf8))
        let observedTransfer4 = try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(observedTransfer4,head)
    }
    func testAmbiguousWorkingAliasesRejectMoveRenameClipboardCopyAndStageBeforeMutation() async throws {
        let (root,repo) = try await CommitSelectionTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        let a = "café.txt", b = "cafe\u{301}.txt", folder = root.appendingPathComponent("target")
        _ = try await repo.run(["config","core.precomposeunicode","true"])
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("working\n".utf8).write(to:root.appendingPathComponent(a))
        try Data("external\n".utf8).write(to:root.appendingPathComponent("external"))
        try await installExact(a,text:"first\n",repo:repo);try await installExact(b,text:"second\n",repo:repo)
        _ = try await repo.commit(message:"aliases")
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse","HEAD"]).stdout
        do {_ = try await repo.prepareFileMove(source:b,to:folder);XCTFail("Moved an ambiguous local alias")}catch FileMoveFailure.ambiguousPath{}
        do {_ = try await repo.prepareRename(.init(source:a,name:"renamed"));XCTFail("Renamed an ambiguous local alias")}catch RenameFailure.ambiguousPath{}
        do {_ = try await repo.clipboardMovePaths([root.appendingPathComponent(a)]);XCTFail("Enabled an ambiguous clipboard move")}catch FileMoveFailure.ambiguousPath{}
        do {_ = try await repo.prepareFileCopy(source:root.appendingPathComponent("external"),to:root,name:b);XCTFail("Copied over an ambiguous index alias")}catch FileMoveFailure.ambiguousPath{}
        do {_ = try await repo.stageCopiedItem(a,ignoredRepositories:[]);XCTFail("Staged an ambiguous index alias")}catch FileMoveFailure.ambiguousPath{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let observedTransfer5 = try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(observedTransfer5,head)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(a)),Data("working\n".utf8))
    }
    func testCopyOverwriteAndClipboardResolveOneExistingIndexSpelling() async throws {
        let (root,repo) = try await CommitSelectionTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        let a = "café.txt", b = "cafe\u{301}.txt", source = root.appendingPathComponent("external")
        _ = try await repo.run(["config","core.precomposeunicode","true"])
        try Data("old\n".utf8).write(to:root.appendingPathComponent(b));try Data("new\n".utf8).write(to:source)
        try await installExact(b,text:"old\n",repo:repo);_ = try await repo.commit(message:"base")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        let clipboard = try await repo.clipboardMovePaths([root.appendingPathComponent(a)])
        XCTAssertEqual(clipboard.map {GitReferenceName($0)},[GitReferenceName(b)])
        let plan = try await repo.prepareFileCopy(source:source,to:root,name:a)
        XCTAssertTrue(GitReferenceName.equal(plan.destination,b));XCTAssertTrue(plan.occupied)
        let copied = try await repo.copyWorkingItem(plan,overwrite:true);_ = try await repo.stageCopiedItem(copied.destination,ignoredRepositories:[])
        let observedTransfer6 = try await repo.run(["-c","core.precomposeunicode=false","ls-files","-z"]).stdout
        XCTAssertEqual(observedTransfer6,Data((b+"\0").utf8))
        let observedTransfer7 = try await repo.run(["-c","core.precomposeunicode=false","show",":"+b]).stdout
        XCTAssertEqual(observedTransfer7,Data("new\n".utf8))
        XCTAssertEqual(try Data(contentsOf:source),Data("new\n".utf8))
        let observedTransfer8 = try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(observedTransfer8,head)
    }

    func testDestinationFolderUsesUniqueTrackedSpellingFromFilesystemURL() async throws {
        let (root,repo) = try await CommitSelectionTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        let directory = "café", source = directory+"/file", folder = root.appendingPathComponent(directory)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("working\n".utf8).write(to:folder.appendingPathComponent("file"))
        try await installExact(source,text:"staged\n",repo:repo);_ = try await repo.commit(message:"parent spelling")
        do {_ = try await repo.prepareFileMove(source:source,to:folder);XCTFail("Moving to its own folder changed ancestor spelling")}catch FileMoveFailure.unchanged{}
        let plan = try await repo.prepareFileMove(source:source,to:folder,name:"renamed")
        XCTAssertTrue(GitReferenceName.equal(plan.destination,directory+"/renamed"))
        _ = try await repo.executeFileMove(plan)
        let paths = try await repo.run(["-c","core.precomposeunicode=false","ls-files","-z"]).stdout
        XCTAssertEqual(paths,Data((directory+"/renamed\0").utf8))
        let staged = try await repo.run(["-c","core.precomposeunicode=false","show",":"+directory+"/renamed"]).stdout
        XCTAssertEqual(staged,Data("staged\n".utf8))
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("renamed")),Data("working\n".utf8))
    }

}
