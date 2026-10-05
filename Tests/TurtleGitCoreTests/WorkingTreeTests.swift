import XCTest
@testable import TurtleGitCore

final class WorkingTreeTests: XCTestCase {
    func testIndexFlagMarkedStatusGatesIncludeCombinedAddedDeletedAndUnversionedActions() {
        for (code, skip, assume) in [(" M", true, true), ("A ", false, false), ("AD", false, false), (" D", true, false), ("D ", true, false), ("UU", false, false), ("??", false, false), ("!!", false, false)] {
            let entry = StatusEntry.parse(Data((code + " path\0").utf8))[0]
            let file = WorkingTreeFile(entry: entry, assumeUnchanged: false, skipWorktree: false, modificationDate: nil)
            XCTAssertEqual(IndexFlagAction.skipWorktree.isAvailable(for: [file]), skip, code)
            XCTAssertEqual(IndexFlagAction.assumeUnchanged.isAvailable(for: [file]), assume, code)
        }
        let retained = StatusEntry.parse(Data("D  path\0?? path\0".utf8))[0]
        let file = WorkingTreeFile(entry: retained, assumeUnchanged: true, skipWorktree: true, modificationDate: nil)
        for action in IndexFlagAction.allCases { XCTAssertFalse(action.isAvailable(for: [file])) }
    }
    func testMarkedFlagActionUpdatesIndexedSelectionAndReportsUnavailablePaths() async throws {
        let (root, repo, mark) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let added = ":(glob)* added 雪\n.txt", untracked = "untracked.txt"
        try Data("added\n".utf8).write(to: root.appendingPathComponent(added)); try await repo.stage([added])
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent(untracked))
        try Data("working mark\n".utf8).write(to: root.appendingPathComponent(mark))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let entries = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let baseline = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        do { try await repo.setIndexFlags(.skipWorktree, paths: [mark, added, untracked], markedPath: untracked); XCTFail("Reject an ineligible mark") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), baseline)
        do { try await repo.setIndexFlags(.skipWorktree, paths: [mark, added, untracked], markedPath: mark); XCTFail("Report unavailable path") }
        catch let failure as IndexFlagPartialFailure {
            XCTAssertEqual(Set(failure.updatedPaths), [mark, added]); XCTAssertEqual(failure.unavailablePaths, [untracked])
        }
        let rows = try await repo.workingTreeStatus(refreshIndex: false)
        XCTAssertTrue(rows.filter { [mark, added].contains($0.id) }.allSatisfy(\.skipWorktree))
        // The mark can be outside the highlight, as in the upstream status list.
        try await repo.setIndexFlags(.clear, paths: [added], markedPath: mark)
        let cleared = try await repo.workingTreeStatus(refreshIndex: false)
        XCTAssertFalse(try XCTUnwrap(cleared.first { $0.id == added }).skipWorktree)
        XCTAssertTrue(try XCTUnwrap(cleared.first { $0.id == mark }).skipWorktree)
        try await repo.setIndexFlags(.clear, paths: [mark], markedPath: mark)
        let finalEntries = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(entries, finalEntries); XCTAssertEqual(head, finalHead)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(mark)), Data("working mark\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(added)), Data("added\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(untracked)), Data("untracked\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }
    func testScopedStatusIncludesOtherStagedFilesOnlyWhenEnabledAndPreservesMixedChanges() async throws {
        let (root, repo, unusual) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("base\n".utf8).write(to: root.appendingPathComponent("folder/inside.txt"))
        try await repo.stage(["folder/inside.txt"]); _ = try await repo.commit(message: "inside")
        try Data("index change\n".utf8).write(to: root.appendingPathComponent(unusual)); try await repo.stage([unusual])
        try Data("later working change\n".utf8).write(to: root.appendingPathComponent(unusual))
        try Data("inside changed\n".utf8).write(to: root.appendingPathComponent("folder/inside.txt"))
        let rows = try await repo.workingTreeStatus()
        var filter = WorkingTreeFilter(); filter.paths = ["folder"]; filter.wholeProject = false
        XCTAssertEqual(Set(rows.filter(filter.includes).map(\.id)), [unusual, "folder/inside.txt"])
        filter.showAllStaged = false
        XCTAssertEqual(rows.filter(filter.includes).map(\.id), ["folder/inside.txt"])
        filter.paths = [unusual]
        XCTAssertEqual(rows.filter(filter.includes).map(\.id), [unusual], "Turning off show-all-staged must retain staged files inside scope")
        let diff = try await repo.workingTreeDiff(paths: [unusual])
        XCTAssertTrue(diff.contains("+later working change")); XCTAssertFalse(diff.contains("+index change"))
        let index = try await repo.run(["show", ":" + unusual]).text
        XCTAssertEqual(index, "index change\n")
    }
    func testCleanIgnoredUnversionedAndIndexFlagsWithLiteralNames() async throws {
        let (root, repo, unusual) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("*.ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("sample.ignored"))
        var rows = try await repo.workingTreeStatus(), filter = WorkingTreeFilter()
        XCTAssertEqual(rows.first { $0.id == unusual }?.state, .normal)
        XCTAssertFalse(rows.filter(filter.includes).contains { $0.id == unusual || $0.id == "sample.ignored" })
        XCTAssertTrue(rows.filter(filter.includes).contains { $0.id == ".gitignore" })
        filter.showUnversioned = false; filter.showIgnored = true; filter.showUnmodified = true
        XCTAssertEqual(Set(rows.filter(filter.includes).map(\.id)), [unusual, "sample.ignored"])
        _ = try await repo.run(["update-index", "--assume-unchanged", "--", unusual])
        rows = try await repo.workingTreeStatus()
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.id == unusual }).assumeUnchanged)
        XCTAssertFalse(rows.filter(filter.includes).contains { $0.id == unusual })
        filter.showLocalChangesIgnored = true
        XCTAssertTrue(rows.filter(filter.includes).contains { $0.id == unusual })
        _ = try await repo.run(["update-index", "--skip-worktree", "--", unusual])
        rows = try await repo.workingTreeStatus()
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.id == unusual }).skipWorktree)
    }
    func testUnbornWorkingTreeDiffIncludesIndexWithoutCreatingHead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        try Data("new line\n".utf8).write(to: root.appendingPathComponent("new.txt")); try await repo.stage(["new.txt"])
        let diff = try await repo.workingTreeDiff(paths: ["new.txt"])
        XCTAssertTrue(diff.contains("+new line"))
        let rows = try await repo.workingTreeStatus(); XCTAssertEqual(rows.first?.state, .added)
    }
    func testIndexFlagActionsPreserveBothContentsAndClearBothFlagsWithLiteralPaths() async throws {
        let (root, repo, unusual) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = ":(glob)* [literal].txt"
        try Data("base other\n".utf8).write(to: root.appendingPathComponent(other))
        try await repo.stage([other]); _ = try await repo.commit(message: "other")
        try Data("staged contents\n".utf8).write(to: root.appendingPathComponent(unusual))
        try await repo.stage([unusual])
        let working = Data("working contents 雪\n".utf8)
        try working.write(to: root.appendingPathComponent(unusual))
        try Data("other working\n".utf8).write(to: root.appendingPathComponent(other))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let indexEntries = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let paths = [unusual, other]
        try await repo.setIndexFlags(.assumeUnchanged, paths: paths)
        try await repo.setIndexFlags(.skipWorktree, paths: paths)
        var files = try await repo.workingTreeStatus().filter { paths.contains($0.id) }
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.assumeUnchanged && $0.skipWorktree })
        XCTAssertFalse(IndexFlagAction.assumeUnchanged.isAvailable(for: files))
        XCTAssertFalse(IndexFlagAction.skipWorktree.isAvailable(for: files))
        XCTAssertTrue(IndexFlagAction.clear.isAvailable(for: files))
        try await repo.setIndexFlags(.clear, paths: paths)
        files = try await repo.workingTreeStatus().filter { paths.contains($0.id) }
        XCTAssertTrue(files.allSatisfy { !$0.assumeUnchanged && !$0.skipWorktree })
        XCTAssertEqual(files.first { $0.id == unusual }?.entry.index, "M")
        XCTAssertEqual(files.first { $0.id == unusual }?.entry.worktree, "M")
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let finalEntries = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(head, finalHead); XCTAssertEqual(indexEntries, finalEntries)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(unusual)), working)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(other)), Data("other working\n".utf8))
    }
    func testInvalidIndexFlagSelectionAndIndexLockLeaveIndexUntouched() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let untracked = "untracked.txt", added = "added.txt"
        try Data("new".utf8).write(to: root.appendingPathComponent(untracked))
        try Data("added".utf8).write(to: root.appendingPathComponent(added)); try await repo.stage([added])
        let baseline = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        for paths in [[path, untracked], [path, added], [path, "missing"], []] {
            do { try await repo.setIndexFlags(.skipWorktree, paths: paths); XCTFail("Invalid selection accepted") }
            catch { }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), baseline)
        }
        try await repo.setIndexFlags(.skipWorktree, paths: [path])
        let flaggedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let lock = root.appendingPathComponent(".git/index.lock")
        try Data("existing lock".utf8).write(to: lock)
        for action in [IndexFlagAction.assumeUnchanged, .clear] {
            do { try await repo.setIndexFlags(action, paths: [path]); XCTFail("Locked index accepted") }
            catch { }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), flaggedIndex)
        }
        XCTAssertEqual(try Data(contentsOf: lock), Data("existing lock".utf8))
    }

    func testClearFlagsUsesLinkedWorktreeIndexAndPreservesPermissions() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linked) }
        _ = try await repo.run(["worktree", "add", "-b", "flags", linked.path])
        let linkedRepo = GitRepository(root: linked)
        try Data("linked working\n".utf8).write(to: linked.appendingPathComponent(path))
        let mainIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try await linkedRepo.setIndexFlags(.assumeUnchanged, paths: [path])
        try await linkedRepo.setIndexFlags(.skipWorktree, paths: [path])
        let location = try await linkedRepo.run(["rev-parse", "--git-path", "index"]).text.trimmingCharacters(in: .newlines)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: location)
        try await linkedRepo.setIndexFlags(.clear, paths: [path])
        let files = try await linkedRepo.workingTreeStatus(refreshIndex: false)
        let row = try XCTUnwrap(files.first { $0.id == path })
        XCTAssertFalse(row.assumeUnchanged); XCTAssertFalse(row.skipWorktree)
        XCTAssertEqual(row.state, .modified)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), mainIndex)
        XCTAssertEqual(try Data(contentsOf: linked.appendingPathComponent(path)), Data("linked working\n".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: location)[.posixPermissions] as? Int, 0o640)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location + ".lock"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location + ".lock.lock"))
    }

}
