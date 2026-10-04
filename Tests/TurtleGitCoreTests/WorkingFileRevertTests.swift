import XCTest
@testable import TurtleGitCore

final class WorkingFileRevertTests: XCTestCase {
    func testModifiedBinaryRevertsIndexAndWorktreeAndRetainsLaterBytesInTrash() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try Data(contentsOf: root.appendingPathComponent(path))
        let other = "other.txt"; try Data("other base".utf8).write(to: root.appendingPathComponent(other))
        try await repo.stage([other]); _ = try await repo.commit(message: "other")
        try Data("other staged".utf8).write(to: root.appendingPathComponent(other)); try await repo.stage([other])
        try Data([0, 255, 13, 10]).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        let working = Data([0, 254, 65]); try working.write(to: root.appendingPathComponent(path))
        let selected = try await repo.status().filter { $0.path == path }, head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let output = try await repo.revertWorkingFiles(selected), trash = try XCTUnwrap(output.trashedFiles.first)
        defer { try? FileManager.default.removeItem(at: trash) }
        XCTAssertEqual(try Data(contentsOf: trash), working)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), base)
        let staged = try await repo.run(["show", ":" + path]).stdout
        let unrelated = try await repo.run(["show", ":" + other]).stdout
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(staged, base); XCTAssertEqual(unrelated, Data("other staged".utf8)); XCTAssertEqual(afterHead, head)
    }
    func testAddedLiteralFileRetainsWorkingContentsWhenRevertedBeforeInitialCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root), path = ":(glob)* 雪\n.txt", bytes = Data("keep me".utf8)
        _ = try await repo.run(["init"]); try bytes.write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        let selected = try await repo.status()
        _ = try await repo.revertWorkingFiles(selected)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        let tracked = try await repo.trackedPaths(), status = try await repo.status()
        XCTAssertTrue(tracked.isEmpty); XCTAssertEqual(status.first?.state, .untracked)
    }
    func testStagedRenameReturnsOldNameAndRecyclesDestination() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try Data(contentsOf: root.appendingPathComponent(path)), renamed = "renamed 雪.txt"
        _ = try await repo.run(["mv", "--", path, renamed])
        let edits = base + Data("later edit\n".utf8); try edits.write(to: root.appendingPathComponent(renamed))
        let selected = try await repo.status()
        XCTAssertEqual(selected.first?.originalPath, path)
        let output = try await repo.revertWorkingFiles(selected), trash = try XCTUnwrap(output.trashedFiles.first)
        defer { try? FileManager.default.removeItem(at: trash) }
        XCTAssertEqual(try Data(contentsOf: trash), edits)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(renamed).path))
        let status = try await repo.status(); XCTAssertTrue(status.isEmpty)
    }
    func testDeletedFileRestoredAndAmendUsesParentEvenWhenShowingHead() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try Data(contentsOf: root.appendingPathComponent(path))
        try Data("last commit".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "last")
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        let selected = try await repo.status(), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        _ = try await repo.revertWorkingFiles(selected, amend: true, amendDiffToLastCommit: true)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), base)
        let staged = try await repo.run(["show", ":" + path]).stdout, afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(staged, base); XCTAssertEqual(afterHead, head)
    }
    func testInvalidMixedStaleAndIndexLockedSelectionsDoNotMoveWorkingFiles() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("working".utf8); try bytes.write(to: root.appendingPathComponent(path))
        try Data("untracked".utf8).write(to: root.appendingPathComponent("new"))
        let status = try await repo.status(), selected = status.filter { $0.path == path }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        do { _ = try await repo.revertWorkingFiles(status); XCTFail("Mixed untracked selection accepted") } catch {}
        let lock = root.appendingPathComponent(".git/index.lock"); try Data("external lock".utf8).write(to: lock)
        do { _ = try await repo.revertWorkingFiles(selected); XCTFail("External index lock accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: lock), Data("external lock".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        try FileManager.default.removeItem(at: lock); try await repo.stage([path])
        do { _ = try await repo.revertWorkingFiles(selected); XCTFail("Stale selection accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
    }
    func testRevertGitlinkConflictPreservesInitializedAndUninitializedChildContents() async throws {
        for initialized in [false, true] {
            let (root, source, repo, child, path) = try await ConflictResolutionTests().submoduleFixture(initialized: initialized)
            defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
            let selected = try await repo.status().filter { $0.path == path }
            let expected = try await repo.run(["ls-tree", "HEAD", "--", path]).text.split(separator: " ")[2].split(separator: "\t")[0]
            var bytes: Data?, childHead: Data?
            if let child {
                try Data("local edits remain".utf8).write(to: child.root.appendingPathComponent("file.txt"))
                bytes = try Data(contentsOf: child.root.appendingPathComponent("file.txt"))
                childHead = try await child.run(["rev-parse", "HEAD"]).stdout
            }
            let result = try await repo.revertWorkingFiles(selected)
            XCTAssertTrue(result.trashedFiles.isEmpty)
            let indexed = try await repo.run(["ls-files", "--stage", "--", path]).text
            XCTAssertTrue(indexed.hasPrefix("160000 " + expected + " 0\t"))
            let conflicts = try await repo.conflicts(); XCTAssertTrue(conflicts.isEmpty)
            if let child {
                XCTAssertEqual(try Data(contentsOf: child.root.appendingPathComponent("file.txt")), bytes)
                let afterChild = try await child.run(["rev-parse", "HEAD"]).stdout
                XCTAssertEqual(afterChild, childHead)
            }
        }
    }
    func testRevertSymlinkAndRejectEscapingParent() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside untouched".utf8).write(to: outside.appendingPathComponent("file"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "original missing target")
        try await repo.stage(["link"]); _ = try await repo.commit(message: "symlink")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.appendingPathComponent("file").path)
        let selected = try await repo.status().filter { $0.path == "link" }, result = try await repo.revertWorkingFiles(selected)
        defer { for trash in result.trashedFiles { try? FileManager.default.removeItem(at: trash) } }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "original missing target")
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file")), Data("outside untouched".utf8))
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: folder.appendingPathComponent("file"))
        try await repo.stage(["folder/file"]); _ = try await repo.commit(message: "folder")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(atPath: folder.path, withDestinationPath: outside.path)
        let escaping = try await repo.status().filter { $0.path == "folder/file" }
        do { _ = try await repo.revertWorkingFiles(escaping); XCTFail("Escaping parent accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file")), Data("outside untouched".utf8))
    }

    func testSubmoduleRenameReturnsCheckoutToOldPathWithoutLosingLocalEdits() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        let (source, _, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        _ = try await repo.run(["-c", "protocol.file.allow=always", "submodule", "add", "--", source.path, "module"])
        try await repo.stage([".gitmodules", "module"]); _ = try await repo.commit(message: "module")
        _ = try await repo.run(["mv", "--", "module", "renamed-module"])
        let child = GitRepository(root: root.appendingPathComponent("renamed-module"))
        try Data("child local edit".utf8).write(to: child.root.appendingPathComponent("local.txt"))
        let head = try await child.run(["rev-parse", "HEAD"]).stdout
        let selected = try await repo.status().filter { $0.path == "renamed-module" }
        XCTAssertEqual(selected.first?.originalPath, "module")
        _ = try await repo.revertWorkingFiles(selected)
        let restored = GitRepository(root: root.appendingPathComponent("module"))
        XCTAssertEqual(try Data(contentsOf: restored.root.appendingPathComponent("local.txt")), Data("child local edit".utf8))
        let afterHead = try await restored.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(afterHead, head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.root.path))
        let indexed = try await repo.run(["ls-files", "--stage", "--", "module"]).text
        XCTAssertTrue(indexed.hasPrefix("160000 "))
        let config = try await repo.run(["config", "-f", ".gitmodules", "submodule.module.path"]).text
        XCTAssertEqual(config.trimmingCharacters(in: .newlines), "module")
    }
    func testLinkedWorktreeRevertUsesItsOwnIndex() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        let linked = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: linked) }
        _ = try await repo.run(["worktree", "add", "-b", "linked-revert", "--", linked.path])
        let child = GitRepository(root: linked), base = try Data(contentsOf: linked.appendingPathComponent(path))
        let mainIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("linked edits".utf8).write(to: linked.appendingPathComponent(path)); try await child.stage([path])
        let selected = try await child.status(), result = try await child.revertWorkingFiles(selected)
        defer { for trash in result.trashedFiles { try? FileManager.default.removeItem(at: trash) } }
        XCTAssertEqual(try Data(contentsOf: linked.appendingPathComponent(path)), base)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), mainIndex)
        let status = try await child.status(); XCTAssertTrue(status.isEmpty)
    }
    func testConflictedFileRevertRestoresHeadWhileKeepingMergeAndUnrelatedEdits() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try await repo.status().filter { $0.path == path }
        let conflictBytes = try Data(contentsOf: root.appendingPathComponent(path))
        let mergeHead = try await repo.run(["rev-parse", "MERGE_HEAD"]).stdout
        let result = try await repo.revertWorkingFiles(selected), trash = try XCTUnwrap(result.trashedFiles.first)
        defer { try? FileManager.default.removeItem(at: trash) }
        XCTAssertEqual(try Data(contentsOf: trash), conflictBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("mine\n".utf8))
        let staged = try await repo.run(["show", ":other.txt"]).text
        let afterMerge = try await repo.run(["rev-parse", "MERGE_HEAD"]).stdout
        let conflicts = try await repo.conflicts()
        XCTAssertEqual(staged, "other index\n"); XCTAssertEqual(afterMerge, mergeHead); XCTAssertTrue(conflicts.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "other working\n")
    }

    func testCheckoutFilterFailureKeepsRealIndexAndReportsRecoverableWorkingCopy() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "smudge.txt", location = root.appendingPathComponent(path)
        try Data("base".utf8).write(to: location)
        try Data("smudge.txt filter=qa\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try await repo.stage([path, ".gitattributes"]); _ = try await repo.commit(message: "filtered base")
        _ = try await repo.run(["config", "filter.qa.smudge", "false"])
        _ = try await repo.run(["config", "filter.qa.required", "true"])
        try Data("later edits".utf8).write(to: location)
        let selected = try await repo.status().filter { $0.path == path }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        do { _ = try await repo.revertWorkingFiles(selected); XCTFail("Failing smudge filter accepted") }
        catch let failure as WorkingFileRevertFailure {
            let trash = try XCTUnwrap(failure.trashedFiles.first)
            defer { try? FileManager.default.removeItem(at: trash) }
            XCTAssertEqual(try Data(contentsOf: trash), Data("later edits".utf8))
            XCTAssertTrue(failure.localizedDescription.contains(trash.path))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }

}
