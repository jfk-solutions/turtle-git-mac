import XCTest
@testable import TurtleGitCore

final class WorkingFileDeleteTests: XCTestCase {
    func testCancellationStopsStatusInspectionBeforeDeletingOrLockingIndex() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "unversioned", bytes = Data("preserved\n".utf8)
        try bytes.write(to: root.appendingPathComponent(path))
        let selected = try await repository.status(refreshIndex: false).filter { $0.path == path }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let helper = root.appendingPathComponent("slow-git"), ready = root.appendingPathComponent("ready")
        let script = """
        #!/bin/sh
        if [ "$4" = status ]; then : > "$3/ready"; /bin/sleep 30; fi
        exec /usr/bin/git "$@"
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let slow = GitRepository(root: root, executable: helper), token = OperationCancellation()
        let task = Task { try await slow.deleteWorkingFiles(selected, permanently: true, cancellation: token) }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = FileManager.default.fileExists(atPath: ready.path); token.cancel()
        do { _ = try await task.value; XCTFail("Cancelled deletion completed") } catch is GitCommandCancellationFailure {} catch is OperationCancellationFailure {}
        XCTAssertTrue(started)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }

    func testTrashPreservesLiteralBinaryContentsAndUnrelatedStaging() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("retained staging\n".utf8).write(to: root.appendingPathComponent(tracked))
        try await repository.stage([tracked])
        let path = ":(glob)雪,\n.bin", bytes = Data([0, 255, 13, 10])
        try bytes.write(to: root.appendingPathComponent(path))
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let index = root.appendingPathComponent(".git/index"), original = try Data(contentsOf: index)
        let selected = try await repository.status(refreshIndex: false).filter { $0.path == path }
        let result = try await repository.deleteWorkingFiles(selected)
        defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(result.removedPaths, [path]); XCTAssertEqual(result.removedIndexPaths, [])
        XCTAssertEqual(result.trashedFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.trashedFiles.first)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        XCTAssertEqual(try Data(contentsOf: index), original)
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(finalHead, head)
    }

    func testMissingTrackedFileRemovesOnlyItsIndexEntryWithSplitIndex() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep\n".utf8).write(to: root.appendingPathComponent("retained")); try await repository.stage(["retained"])
        _ = try await repository.run(["update-index", "--split-index"])
        let retained = try await repository.run(["ls-files", "--stage", "-z", "--", "retained"]).stdout
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        try FileManager.default.removeItem(at: root.appendingPathComponent(tracked))
        let selected = try await repository.status(refreshIndex: false).filter { $0.path == tracked }
        let result = try await repository.deleteWorkingFiles(selected)
        XCTAssertEqual(result.removedIndexPaths, [tracked]); XCTAssertTrue(result.trashedFiles.isEmpty)
        let finalTracked = try await repository.run(["ls-files", "--stage", "-z", "--", tracked]).stdout
        let finalRetained = try await repository.run(["ls-files", "--stage", "-z", "--", "retained"]).stdout
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertTrue(finalTracked.isEmpty); XCTAssertEqual(finalRetained, retained); XCTAssertEqual(finalHead, head)
    }

    func testMixedSelectionTrashesTrackedWorkingEditsAndUntrackedFile() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("working edits 雪\n".utf8)
        try bytes.write(to: root.appendingPathComponent(tracked)); try Data([7]).write(to: root.appendingPathComponent("new"))
        let selected = try await repository.status(refreshIndex: false)
        let result = try await repository.deleteWorkingFiles(selected)
        defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(Set(result.removedPaths), Set([tracked, "new"]))
        XCTAssertEqual(result.removedIndexPaths, [tracked]); XCTAssertEqual(result.trashedFiles.count, 2)
        let recovered = try result.trashedFiles.map { try Data(contentsOf: $0) }
        XCTAssertTrue(recovered.contains(bytes)); XCTAssertTrue(recovered.contains(Data([7])))
        let finalTracked = try await repository.run(["ls-files", "--stage", "-z", "--", tracked]).stdout
        XCTAssertTrue(finalTracked.isEmpty)
    }

    func testStaleCancelledAndLockedSelectionLeavesFilesAndIndexUntouched() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "new", file = root.appendingPathComponent(path), bytes = Data([3])
        try bytes.write(to: file)
        let selected = try await repository.status(refreshIndex: false).filter { $0.path == path }
        let index = root.appendingPathComponent(".git/index"), original = try Data(contentsOf: index)
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await repository.deleteWorkingFiles(selected, cancellation: cancellation); XCTFail("Cancelled operation accepted") } catch {}
        let lock = root.appendingPathComponent(".git/index.lock"); try Data([99]).write(to: lock)
        do { _ = try await repository.deleteWorkingFiles(selected); XCTFail("Existing index lock overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: lock), Data([99])); try FileManager.default.removeItem(at: lock)
        try await repository.stage([path])
        let stagedIndex = try Data(contentsOf: index)
        do { _ = try await repository.deleteWorkingFiles(selected); XCTFail("Stale selection accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: index), stagedIndex); XCTAssertNotEqual(stagedIndex, original)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testUnselectedMarkEnablesTrackedSelectionAndRejectsStaleMark() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(tracked), bytes = Data("changed working bytes\n".utf8)
        try bytes.write(to: file); try Data([7]).write(to: root.appendingPathComponent("mark"))
        let status = try await repository.status(refreshIndex: false)
        let selected = status.filter { $0.path == tracked }, mark = try XCTUnwrap(status.first { $0.path == "mark" })
        let index = root.appendingPathComponent(".git/index"), original = try Data(contentsOf: index)
        try await repository.stage(["mark"])
        let stagedIndex = try Data(contentsOf: index)
        do { _ = try await repository.deleteWorkingFiles(selected, selectionMark: mark); XCTFail("Stale selection mark accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes); XCTAssertEqual(try Data(contentsOf: index), stagedIndex)
        _ = try await repository.run(["reset", "--", "mark"])
        let result = try await repository.deleteWorkingFiles(selected, selectionMark: mark)
        defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(result.removedPaths, [tracked]); XCTAssertEqual(result.removedIndexPaths, [tracked])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.trashedFiles.first)), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("mark")), Data([7]))
        XCTAssertNotEqual(try Data(contentsOf: index), original)
    }

    func testIndexDeletedPathWithUnversionedCopyCanBeDeleted() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(tracked), bytes = try Data(contentsOf: file)
        _ = try await repository.run(["rm", "--cached", "--", tracked])
        let selected = try await repository.status(refreshIndex: false).filter { $0.path == tracked }
        let entry = try XCTUnwrap(selected.first)
        XCTAssertTrue(entry.hasUnversionedCopy); XCTAssertTrue(entry.canDeleteWithKeyboard)
        let index = root.appendingPathComponent(".git/index"), original = try Data(contentsOf: index)
        let result = try await repository.deleteWorkingFiles(selected)
        defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.trashedFiles.first)), bytes)
        XCTAssertTrue(result.removedIndexPaths.isEmpty); XCTAssertEqual(try Data(contentsOf: index), original)
    }

    private func retainedIgnoredCopyFixture() async throws -> (URL,GitRepository,String,String,Data) {
        let (root,repository,tracked)=try await GitPatchTests().fixture()
        let path="retained Café 雪.txt",bytes=Data([0,255,13,10])+Data("retained copy\n".utf8)
        try bytes.write(to:root.appendingPathComponent(path));try await repository.stage([path])
        _ = try await repository.commit(message:"retained copy baseline")
        _ = try await repository.run(["rm","--cached","--",path])
        let exclude=root.appendingPathComponent(".git/info/exclude")
        var rules=try Data(contentsOf:exclude);rules.append(Data(("\n/"+path+"\n").utf8));try rules.write(to:exclude)
        return(root,repository,tracked,path,bytes)
    }

    func testDialogIgnoredRetainedCopyKeepsExactRecoverableBytesIndexAndHead() async throws {
        let (root,repository,tracked,path,bytes)=try await retainedIgnoredCopyFixture()
        defer {try? FileManager.default.removeItem(at:root)}
        // Retain unrelated real staging while exercising the dialog's omission
        // of !! rows, rather than constructing a permissive synthetic status.
        try Data("unrelated staged\n".utf8).write(to:root.appendingPathComponent(tracked));try await repository.stage([tracked])
        let index=root.appendingPathComponent(".git/index"),beforeIndex=try Data(contentsOf:index)
        let head=try await repository.run(["rev-parse","HEAD"]).stdout
        let selected=try await repository.commitDialogStatus(amendToParent:false,refreshIndex:false).filter{GitReferenceName.equal($0.path,path)}
        let entry=try XCTUnwrap(selected.first)
        XCTAssertEqual(selected.count,1);XCTAssertEqual(entry.index,"D");XCTAssertTrue(entry.hasUnversionedCopy);XCTAssertNil(entry.unversionedCopyState)
        let fresh=try await repository.status(refreshIndex:false)
        XCTAssertEqual(fresh.first{GitReferenceName.equal($0.path,path)}?.unversionedCopyState,.ignored)
        let result=try await repository.deleteWorkingFiles(selected,selectionMark:entry)
        defer {for item in result.trashedFiles {try? FileManager.default.removeItem(at:item)}}
        XCTAssertEqual(result.removedPaths,[path]);XCTAssertTrue(result.removedIndexPaths.isEmpty)
        XCTAssertEqual(result.trashedFiles.count,1)
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(result.trashedFiles.first)),bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path))
        XCTAssertEqual(try Data(contentsOf:index),beforeIndex)
        let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(afterHead,head)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(tracked)),Data("unrelated staged\n".utf8))
    }

    func testScopedDialogUnknownRetainedUntrackedCopyDeletesWithoutTouchingOtherState() async throws {
        let (root,repository,tracked,path,bytes)=try await retainedIgnoredCopyFixture()
        defer {try? FileManager.default.removeItem(at:root)}
        try Data().write(to:root.appendingPathComponent(".git/info/exclude"))
        let unrelated=Data("unrelated staged bytes\n".utf8)
        try unrelated.write(to:root.appendingPathComponent(tracked));try await repository.stage([tracked])
        let other=root.appendingPathComponent("other untracked.txt"),otherBytes=Data("other private bytes\n".utf8)
        try otherBytes.write(to:other)
        let index=root.appendingPathComponent(".git/index"),beforeIndex=try Data(contentsOf:index)
        let head=try await repository.run(["rev-parse","HEAD"]).stdout
        // A scoped display also includes global staged names. Its missing-name
        // metadata query intentionally hides unversioned rows, and the shared
        // dialog projection discovers this retained copy without classifying it.
        let snapshot=try await repository.commitDialogRead(amend:false,amendDiffToLastCommit:true,paths:[tracked])
        let selected=snapshot.entries.filter{GitReferenceName.equal($0.path,path)}
        let entry=try XCTUnwrap(selected.first)
        XCTAssertEqual(selected.count,1);XCTAssertEqual(entry.index,"D");XCTAssertTrue(entry.hasUnversionedCopy);XCTAssertNil(entry.unversionedCopyState)
        let fresh=try await repository.status(refreshIndex:false)
        XCTAssertEqual(fresh.first{GitReferenceName.equal($0.path,path)}?.unversionedCopyState,.untracked)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),bytes)
        let result=try await repository.deleteWorkingFiles(selected,selectionMark:entry,permanently:true)
        XCTAssertEqual(result.removedPaths,[path]);XCTAssertTrue(result.removedIndexPaths.isEmpty);XCTAssertTrue(result.trashedFiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path))
        XCTAssertEqual(try Data(contentsOf:index),beforeIndex)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(tracked)),unrelated)
        XCTAssertEqual(try Data(contentsOf:other),otherBytes)
        let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(afterHead,head)
    }

    func testDialogUnknownRetainedCopyMarkAuthorizesOnlyActualTrackedSelection() async throws {
        let (root,repository,tracked,path,bytes)=try await retainedIgnoredCopyFixture()
        defer {try? FileManager.default.removeItem(at:root)}
        let edited=Data("tracked working edit\n".utf8);try edited.write(to:root.appendingPathComponent(tracked))
        let rows=try await repository.commitDialogStatus(amendToParent:false,refreshIndex:false)
        let mark=try XCTUnwrap(rows.first{GitReferenceName.equal($0.path,path)})
        let selected=rows.filter{GitReferenceName.equal($0.path,tracked)}
        XCTAssertNil(mark.unversionedCopyState);XCTAssertTrue(mark.hasUnversionedCopy);XCTAssertEqual(selected.count,1)
        let head=try await repository.run(["rev-parse","HEAD"]).stdout
        let result=try await repository.deleteWorkingFiles(selected,selectionMark:mark)
        defer {for item in result.trashedFiles {try? FileManager.default.removeItem(at:item)}}
        XCTAssertEqual(result.removedPaths,[tracked]);XCTAssertEqual(result.removedIndexPaths,[tracked])
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(result.trashedFiles.first)),edited)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),bytes)
        let remaining=try await repository.run(["ls-files","--stage","-z","--",tracked]).stdout
        XCTAssertTrue(remaining.isEmpty)
        let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(afterHead,head)
    }

    func testKnownRetainedCopyClassificationCannotChangeForSelectionOrMark() async throws {
        let (root,repository,tracked,path,bytes)=try await retainedIgnoredCopyFixture()
        defer {try? FileManager.default.removeItem(at:root)}
        let status=try await repository.status(refreshIndex:false)
        let known=try XCTUnwrap(status.first{GitReferenceName.equal($0.path,path)})
        XCTAssertEqual(known.unversionedCopyState,.ignored)
        // A formerly ignored copy becomes untracked; neither a selected row nor
        // an unselected status-list mark may borrow the unknown-state exception.
        let exclude=root.appendingPathComponent(".git/info/exclude");try Data().write(to:exclude)
        try Data("tracked edit\n".utf8).write(to:root.appendingPathComponent(tracked))
        let current=try await repository.status(refreshIndex:false)
        XCTAssertEqual(current.first{GitReferenceName.equal($0.path,path)}?.unversionedCopyState,.untracked)
        let selected=current.filter{GitReferenceName.equal($0.path,tracked)}
        let index=root.appendingPathComponent(".git/index"),beforeIndex=try Data(contentsOf:index)
        let head=try await repository.run(["rev-parse","HEAD"]).stdout
        for (rows,mark) in [([known],Optional(known)),(selected,Optional(known))] {
            do {_ = try await repository.deleteWorkingFiles(rows,selectionMark:mark);XCTFail("Known retained-copy classification changed")} catch let error as GitFailure {XCTAssertTrue(error.message.contains("selected files changed"))}
            XCTAssertEqual(try Data(contentsOf:index),beforeIndex)
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),bytes)
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(tracked)),Data("tracked edit\n".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath:index.path+".lock"))
        }
        let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(afterHead,head)
    }

    func testUnknownCopyClassificationDoesNotRelaxPathOriginActionsOrXY() async throws {
        let (root,repository,_,path,bytes)=try await retainedIgnoredCopyFixture()
        defer {try? FileManager.default.removeItem(at:root)}
        let rows=try await repository.commitDialogStatus(amendToParent:false,refreshIndex:false)
        let accepted=try XCTUnwrap(rows.first{GitReferenceName.equal($0.path,path)})
        XCTAssertNil(accepted.unversionedCopyState);XCTAssertTrue(accepted.hasUnversionedCopy)
        let wrongOrigin=StatusEntry(path:path,originalPath:"different origin",index:accepted.index,worktree:accepted.worktree,hasUnversionedCopy:true,sourceActions:accepted.sourceActions,sourceOriginalPath:accepted.sourceOriginalPath)
        let wrongPath=StatusEntry(path:path.decomposedStringWithCanonicalMapping,index:accepted.index,worktree:accepted.worktree,hasUnversionedCopy:true,sourceActions:accepted.sourceActions,sourceOriginalPath:accepted.sourceOriginalPath)
        XCTAssertFalse(wrongPath.path.utf8.elementsEqual(path.utf8),"Authored origin/path refusal must exercise different literal Git bytes")
        var wrongActions=accepted;wrongActions.sourceActions = [.deleted]
        var wrongSourceOrigin=accepted;wrongSourceOrigin.sourceOriginalPath="different source origin"
        let index=root.appendingPathComponent(".git/index"),beforeIndex=try Data(contentsOf:index)
        let head=try await repository.run(["rev-parse","HEAD"]).stdout
        for entry in [wrongOrigin,wrongPath,wrongActions,wrongSourceOrigin] {
            do {_ = try await repository.deleteWorkingFiles([entry]);XCTFail("Unknown copy classification relaxed another accepted status fact")} catch let error as GitFailure {XCTAssertTrue(error.message.contains("selected files changed"))}
            XCTAssertEqual(try Data(contentsOf:index),beforeIndex);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),bytes)
        }
        // An actual index transition must also refuse the originally accepted D.
        try Data("new staged bytes\n".utf8).write(to:root.appendingPathComponent(path))
        _ = try await repository.run(["add","-f","--",path])
        let stagedIndex=try Data(contentsOf:index)
        do {_ = try await repository.deleteWorkingFiles([accepted],selectionMark:accepted);XCTFail("Changed XY reused old retained-copy authority")} catch let error as GitFailure {XCTAssertTrue(error.message.contains("selected files changed"))}
        XCTAssertEqual(try Data(contentsOf:index),stagedIndex)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),Data("new staged bytes\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:index.path+".lock"))
        let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(afterHead,head)
    }

    func testTrashMovesSymlinkWithoutTouchingOutsideTarget() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        let target = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target); try? FileManager.default.removeItem(at: root) }
        let bytes = Data("outside target 雪\n".utf8); try bytes.write(to: target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let selected = try await repository.status(refreshIndex: false).filter { $0.path == "link" }
        let result = try await repository.deleteWorkingFiles(selected)
        defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(result.trashedFiles.count, 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: XCTUnwrap(result.trashedFiles.first).path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testPermanentDeleteOfBrokenSymlinkInLinkedWorktreeLeavesMainIndexExact() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        let linked = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: root) }
        _ = try await repository.run(["worktree", "add", "-b", "delete-linked", linked.path])
        let original = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let url = linked.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "absent-target")
        let other = GitRepository(root: linked), selected = try await other.status(refreshIndex: false).filter { $0.path == "broken" }
        let result = try await other.deleteWorkingFiles(selected, permanently: true)
        XCTAssertEqual(result.removedPaths, ["broken"]); XCTAssertTrue(result.trashedFiles.isEmpty)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), original)
    }
}
