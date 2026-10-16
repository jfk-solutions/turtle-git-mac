import XCTest
@testable import TurtleGitCore

final class SavedMergePaneTests: XCTestCase {
    private func configuration() -> SubversionMergeConfiguration {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return .init(executable: root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"),
                     runtimeRoot: root.appendingPathComponent("build/git-runtime/Git"),
                     regexExecutable: root.appendingPathComponent("build/issue-regex-runtime/IssueRegex/issue-regex"))
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitSavedPane-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testHistoricalPaneRebindBecomesCleanAndSavesOnlyChosenFile() throws {
        let root = try directory(), target = root.appendingPathComponent("chosen.txt"), peer = root.appendingPathComponent("peer")
        try Data("peer\n".utf8).write(to: peer)
        let historical = ComparisonFileContent(path: "historical.txt", revision: .revision(String(repeating: "a", count: 40)), bytes: Data("original\r\nlast".utf8), mode: "100644")
        let document = FileComparisonDocument(base: historical, destination: try WorkingFileComparison.workingContent(at: peer))
        var drafts = FileComparisonDrafts(document)
        try historical.bytes.write(to: target)
        let bound = try SavedMergePane(url: target, writtenBytes: historical.bytes, encoding: historical.encoding)
        try drafts.didSaveAs(bound.content, base: true)
        XCTAssertEqual(bound.content.path, target.path); XCTAssertEqual(bound.content.revision, .workingTree)
        XCTAssertTrue(drafts.canEdit(base: true)); XCTAssertFalse(drafts.isDirty(base: true))
        drafts.setEditing(true, base: true); try drafts.update(text: "edited\r\nno newline", base: true)
        let updated = try bound.save(document.replacingPane(base: true, content: bound.content), base: true, text: try XCTUnwrap(drafts.text(base: true)), encoding: .utf16LEBOM, options: .init())
        XCTAssertEqual(try Data(contentsOf: target), try ComparisonTextEncoding.utf16LEBOM.encode("edited\r\nno newline"))
        XCTAssertEqual(updated.base.encoding, .utf16LEBOM)
        XCTAssertEqual(try Data(contentsOf: peer), Data("peer\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("historical.txt").path))
    }
    func testReloadSkipsReboundOriginalAndStaleWritesRequireFreshBaseline() throws {
        let root = try directory(), left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right"), target = root.appendingPathComponent("chosen")
        try Data("left\n".utf8).write(to: left); try Data("right\n".utf8).write(to: right)
        let pair = try WorkingFileComparison(base: left, destination: right), original = try pair.read()
        try original.base.bytes.write(to: target)
        let bound = try SavedMergePane(url: target, writtenBytes: original.base.bytes, encoding: .utf8)
        try FileManager.default.removeItem(at: left)
        try Data("external\n".utf8).write(to: target)
        XCTAssertThrowsError(try bound.validate())
        let fresh = try bound.read(), reloaded = try pair.read(replacements: [true: fresh])
        XCTAssertEqual(reloaded.base.path, target.path); XCTAssertEqual(reloaded.base.bytes, Data("external\n".utf8))
        XCTAssertEqual(reloaded.destination.bytes, original.destination.bytes)
        let saved = try bound.recording(fresh).save(reloaded, base: true, text: "accepted\n", encoding: .utf8, options: .init())
        XCTAssertEqual(saved.base.bytes, Data("accepted\n".utf8)); XCTAssertEqual(try Data(contentsOf: right), Data("right\n".utf8))
    }
    func testStaleSymlinkDeletionAndRecreation() throws {
        let root = try directory(), target = root.appendingPathComponent("target"), other = root.appendingPathComponent("other")
        try Data("saved\n".utf8).write(to: target); try Data("other\n".utf8).write(to: other)
        let bound = try SavedMergePane(url: target, writtenBytes: Data("saved\n".utf8), encoding: .utf8)
        let document = FileComparisonDocument(base: try WorkingFileComparison.workingContent(at: other), destination: bound.content)
        try Data("external\n".utf8).write(to: target)
        XCTAssertThrowsError(try bound.save(document, base: false, text: "overwrite", encoding: .utf8, options: .init()))
        XCTAssertEqual(try Data(contentsOf: target), Data("external\n".utf8))
        try bound.content.bytes.write(to: target)
        let deleted = try bound.save(document, base: false, text: "", encoding: .utf8, options: .init(emptyResult: .delete))
        let absent = try bound.recording(deleted.destination); try absent.validate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let recreated = try absent.save(deleted, base: false, text: "reborn\n", encoding: .utf8, options: .init())
        XCTAssertFalse(recreated.destination.isDeleted); XCTAssertEqual(try Data(contentsOf: target), Data("reborn\n".utf8))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertThrowsError(try SavedMergePane(url: link, writtenBytes: Data(other.path.utf8), encoding: .utf8))
        XCTAssertEqual(try Data(contentsOf: other), Data("other\n".utf8))
    }
    func testThreeFileBindingReloadAndSaveNoLongerReadOriginalSource() async throws {
        let root = try directory(), base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine"), theirs = root.appendingPathComponent("theirs"), target = root.appendingPathComponent("chosen-mine"), output = root.appendingPathComponent("merged")
        for (url, text) in [(base,"base\n"),(mine,"mine\n"),(theirs,"theirs\n"),(target,"chosen\n")] { try Data(text.utf8).write(to: url) }
        let merge = try WorkingTextMerge(base: base, theirs: theirs, mine: mine), engine = configuration()
        _ = try await merge.read(engine: engine)
        let binding = try SavedMergePane(url: target, writtenBytes: Data("chosen\n".utf8), encoding: .utf8)
        try await merge.bindSource(mine: true, target: binding)
        try FileManager.default.removeItem(at: mine)
        let fresh = try await merge.read(engine: engine)
        XCTAssertEqual(fresh.mine, "chosen\n"); XCTAssertEqual(fresh.theirs, "theirs\n")
        _ = try await merge.saveTo(output, document: fresh, result: "resolved\n")
        XCTAssertEqual(try Data(contentsOf: output), Data("resolved\n".utf8))
        try Data("external source\n".utf8).write(to: target)
        do { _ = try await merge.saveTo(output, document: fresh, result: "must refuse\n"); XCTFail("Changed bound input accepted") }
        catch TextConflictFailure.changedWorkingFile {}
        XCTAssertEqual(try Data(contentsOf: output), Data("resolved\n".utf8))
    }
    func testConflictSourceOverlayPreservesWorkingAndIndexIdentity() async throws {
        let root = try directory(), base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine"), theirs = root.appendingPathComponent("theirs"), target = root.appendingPathComponent("chosen")
        for (url, text) in [(base,"base\n"),(mine,"mine\n"),(theirs,"theirs\n")] { try Data(text.utf8).write(to: url) }
        let engine = configuration(), merge = try WorkingTextMerge(base: base, theirs: theirs, mine: mine)
        let original = try await merge.read(engine: engine)
        let bytes = try ComparisonTextEncoding.utf16LEBOM.encode("new source\r\nlast")
        try bytes.write(to: target)
        let bound = try SavedMergePane(url: target, writtenBytes: bytes, encoding: .utf16LEBOM)
        let changed = try original.replacingSources(mine: bound.content, theirs: nil, engine: engine)
        XCTAssertEqual(changed.mine, "new source\r\nlast"); XCTAssertEqual(changed.mineEncoding, .utf16LEBOM)
        XCTAssertEqual(changed.initialResult, original.initialResult); XCTAssertEqual(changed.workingContents, original.workingContents)
        XCTAssertEqual(changed.entry.path, original.entry.path); XCTAssertNotNil(changed.mergeSources)
        let own = try changed.recordingOwnedWorkingWrite(bound.content)
        XCTAssertEqual(own.workingContents, bytes); XCTAssertEqual(own.initialResult, "new source\r\nlast")
    }
}

extension SavedMergePaneTests {
    func testSaveAsPreservesExecutableModeAndRefusesReadOnlyOrLinkTargets() throws {
        let root=try directory(),file=root.appendingPathComponent("existing"),outside=root.appendingPathComponent("outside"),link=root.appendingPathComponent("link")
        try Data("old\n".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        try MergePaneSaveAs.write(Data("chosen\n".utf8),to:file)
        XCTAssertEqual(try Data(contentsOf:file),Data("chosen\n".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber).intValue,0o755)
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:file.path)
        XCTAssertTrue(MergePaneSaveAs.requiresSaveAs(at:file,permissions:0o444))
        XCTAssertThrowsError(try MergePaneSaveAs.write(Data("forbidden".utf8),to:file))
        XCTAssertEqual(try Data(contentsOf:file),Data("chosen\n".utf8))
        try Data("sentinel".utf8).write(to:outside);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        XCTAssertThrowsError(try MergePaneSaveAs.write(Data("forbidden".utf8),to:link))
        XCTAssertEqual(try Data(contentsOf:outside),Data("sentinel".utf8))
        XCTAssertFalse(MergePaneSaveAs.requiresSaveAs(at:file,permissions:0o444,absent:true))
    }
    func testSaveAsEmptyFileThenGuardedBackupDeleteRecreate() throws {
        let root=try directory(),file=root.appendingPathComponent("chosen")
        try MergePaneSaveAs.write(Data(),to:file)
        let target=try SavedMergePane(url:file,writtenBytes:Data(),encoding:.utf8)
        let document=FileComparisonDocument(base:target.content,destination:target.content)
        let deleted=try target.save(document,base:false,text:"",encoding:.utf8,options:.init(backupOriginal:true,emptyResult:.delete))
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:file.path+".bak")),Data())
        let absent=try target.recording(deleted.destination)
        let recreated=try absent.save(deleted,base:false,text:"recreated 🐢\n",encoding:.utf16LEBOM,options:.init(backupOriginal:true))
        XCTAssertEqual(try Data(contentsOf:file),try ComparisonTextEncoding.utf16LEBOM.encode("recreated 🐢\n"))
        XCTAssertFalse(recreated.destination.isDeleted)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:file.path+".bak")),Data())
    }
    func testRecordedMergedDeletionRetainsAbsentSnapshotAndSourceIdentity() async throws {
        let root=try directory(),base=root.appendingPathComponent("base"),mine=root.appendingPathComponent("mine"),theirs=root.appendingPathComponent("theirs"),chosen=root.appendingPathComponent("chosen")
        for (file,text) in [(base,"base\n"),(mine,"mine\n"),(theirs,"theirs\n")] {try Data(text.utf8).write(to:file)}
        let merge=try WorkingTextMerge(base:base,theirs:theirs,mine:mine),document=try await merge.read(engine:configuration())
        try MergePaneSaveAs.write(Data("saved\n".utf8),to:chosen)
        let target=try SavedMergePane(url:chosen,writtenBytes:Data("saved\n".utf8),encoding:.utf8)
        let comparison=FileComparisonDocument(base:target.content,destination:target.content)
        let deleted=try target.save(comparison,base:false,text:"",encoding:.utf8,options:.init(emptyResult:.delete))
        let rebound=try document.recordingOwnedWorkingWrite(deleted.destination)
        XCTAssertNil(rebound.workingContents);XCTAssertEqual(rebound.initialResult,"")
        XCTAssertEqual(rebound.entry,document.entry);XCTAssertEqual(rebound.mine,document.mine);XCTAssertEqual(rebound.theirs,document.theirs)
    }
}

extension SavedMergePaneTests {
    func testCancelledActorSaveRefusesBeforeBackupOrWrite() async throws {
        let root=try directory(),base=root.appendingPathComponent("base"),mine=root.appendingPathComponent("mine"),theirs=root.appendingPathComponent("theirs")
        for (file,text) in [(base,"base\n"),(mine,"mine\n"),(theirs,"theirs\n")] {try Data(text.utf8).write(to:file)}
        let merge=try WorkingTextMerge(base:base,theirs:theirs,mine:mine),document=try await merge.read(engine:configuration())
        let token=OperationCancellation();token.cancel()
        do {_=try await merge.saveTo(mine,document:document,result:"forbidden\n",options:.init(backupOriginal:true),cancellation:token);XCTFail("Cancelled save wrote")} catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf:mine),Data("mine\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:mine.path+".bak"))
    }
}
