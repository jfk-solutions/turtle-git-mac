import XCTest
@testable import TurtleGitCore

final class RepositoryBrowserTests: XCTestCase {
    func testLiteralTreeEntriesModesAndExactBlobContents() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = "folder: 雪", filename = "tab\tand\nnewline.bin"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
        let binary = Data([0, 255, 13, 10])
        try binary.write(to: root.appendingPathComponent(folder + "/" + filename))
        try Data("echo QA\n".utf8).write(to: root.appendingPathComponent("run.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("run.sh").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/missing/target")
        try Data("literal".utf8).write(to: root.appendingPathComponent(":(glob)*.txt"))
        try await repo.stage([folder, "run.sh", "link", ":(glob)*.txt"])
        let previous = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + previous + ",module"])
        _ = try await repo.commit(message: "browser entries")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let snapshot = try await repo.browseRepository()
        XCTAssertEqual(snapshot.entries.first { $0.name == folder }?.kind, .directory)
        let module = try XCTUnwrap(snapshot.entries.first { $0.name == "module" })
        XCTAssertEqual(module.kind, .submodule)
        let description = try await repo.repositoryBrowserFile(snapshot, entry: module)
        XCTAssertEqual(description.path, "module.txt")
        XCTAssertEqual(description.bytes, Data(("Subproject commit " + previous).utf8))
        XCTAssertEqual(snapshot.entries.first { $0.name == "run.sh" }?.kind, .executable)
        let link = try XCTUnwrap(snapshot.entries.first { $0.name == "link" })
        XCTAssertEqual(link.kind, .symlink)
        let target = try await repo.repositoryBrowserFile(snapshot, entry: link)
        XCTAssertEqual(target.bytes, Data("/missing/target".utf8))
        let children = try await repo.browseRepositoryDirectory(snapshot, directory: folder)
        let file = try XCTUnwrap(children.entries.first)
        XCTAssertEqual(file.name, filename); XCTAssertEqual(file.size, 4); XCTAssertEqual(file.fileExtension, ".bin")
        let content = try await repo.repositoryBrowserFile(children, entry: file)
        XCTAssertEqual(content.bytes, binary)
        do { _ = try await repo.repositoryBrowserFile(snapshot, entry: file); XCTFail("Foreign directory entry accepted") } catch is RepositoryBrowserFailure {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testPinnedDirectoryDoesNotFollowMovedReference() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try Data("old".utf8).write(to: root.appendingPathComponent("nested/file.txt"))
        try await repo.stage(["nested"]); _ = try await repo.commit(message: "old tree")
        let first = try await repo.browseRepository()
        try Data("new".utf8).write(to: root.appendingPathComponent("nested/file.txt"))
        try await repo.stage(["nested"]); _ = try await repo.commit(message: "new tree")
        let pinned = try await repo.browseRepositoryDirectory(first, directory: "nested")
        let old = try await repo.repositoryBrowserFile(pinned, entry: XCTUnwrap(pinned.entries.first))
        XCTAssertEqual(old.bytes, Data("old".utf8))
        let latest = try await repo.browseRepository(directory: "nested")
        let new = try await repo.repositoryBrowserFile(latest, entry: XCTUnwrap(latest.entries.first))
        XCTAssertEqual(new.bytes, Data("new".utf8)); XCTAssertNotEqual(first.objectID, latest.objectID)
        for path in ["../nested", "/nested", "nested//child", "nested/file.txt", "missing"] {
            do { _ = try await repo.browseRepositoryDirectory(first, directory: path); XCTFail("Invalid directory accepted: " + path) } catch {}
        }
    }
    func testBareTagsTreesAndUnbornHead() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["tag", "-a", "browser-tag", "-m", "annotated"])
        let tagged = try await repo.browseRepository(revision: "browser-tag")
        let tree = try XCTUnwrap(tagged.treeID)
        let treeSnapshot = try await repo.browseRepository(revision: tree)
        XCTAssertEqual(treeSnapshot.entries, tagged.entries)
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", "--", root.path, bareRoot.path])
        let bare = try await GitRepository(root: bareRoot).browseRepository()
        XCTAssertTrue(bare.bare); XCTAssertEqual(bare.entries, tagged.entries)
        let emptyRoot = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: false)
        let emptyRepo = GitRepository(root: emptyRoot); _ = try await emptyRepo.run(["init"])
        let empty = try await emptyRepo.browseRepository()
        XCTAssertTrue(empty.entries.isEmpty); XCTAssertNil(empty.objectID)
        for invalid in ["missing-revision", "--help", tagged.entries.first { $0.kind == .file }!.objectID] {
            do { _ = try await repo.browseRepository(revision: invalid); XCTFail("Non-tree revision accepted") } catch {}
        }
    }
    func testRevertSupportsSHA256PinnedCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBrowserSHA256-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = ProcessInfo.processInfo.environment["TURTLEGIT_BROWSER_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/git")
        let repo = GitRepository(root: root, executable: executable)
        _ = try await repo.run(["init", "--object-format=sha256", "--initial-branch=main"])
        _ = try await repo.run(["config", "user.name", "Browser QA"]); _ = try await repo.run(["config", "user.email", "browser@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgSign", "false"])
        let path = ":(glob)* 雪.bin", bytes = Data([0, 255, 10])
        try bytes.write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "first")
        let snapshot = try await repo.browseRepository(), entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(snapshot.objectID?.count, 64); XCTAssertEqual(entry.objectID.count, 64)
        try Data("second".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "second")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        try Data("local edits".utf8).write(to: root.appendingPathComponent(path))
        try await repo.revertRepositoryBrowserFile(snapshot, entry: entry)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        let indexed = try await repo.run(["show", ":" + path]).stdout, finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(indexed, bytes); XCTAssertEqual(finalHead, head)
    }
    func testRevertRestoresPinnedBytesModesAndIndexWithoutMovingHead() async throws {
        let (root, fixtureRepo, _) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_BROWSER_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixtureRepo.executable)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = ":(glob)*.bin", binary = Data([0, 255, 10, 13])
        try binary.write(to: root.appendingPathComponent(name))
        try Data("old executable\n".utf8).write(to: root.appendingPathComponent("run.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("run.sh").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "old-target")
        try await repo.stage([name, "run.sh", "link"]); _ = try await repo.commit(message: "original browser files")
        _ = try await repo.run(["tag", "-a", "restore-tag", "-m", "original"])
        let snapshot = try await repo.browseRepository(revision: "restore-tag")
        try Data("new bytes".utf8).write(to: root.appendingPathComponent(name))
        try Data("new executable\n".utf8).write(to: root.appendingPathComponent("run.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("run.sh").path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "new-target")
        try await repo.stage([name, "run.sh", "link"]); _ = try await repo.commit(message: "new browser files")
        // The named tag moves, but the displayed selection must still restore the old blob.
        _ = try await repo.run(["tag", "-f", "restore-tag", "HEAD"])
        try Data("uncommitted".utf8).write(to: root.appendingPathComponent(name))
        try Data("unrelated staged".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
        try await repo.stage(["unrelated.txt"])
        let unrelated = try await repo.run(["ls-files", "--stage", "--", "unrelated.txt"]).stdout
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        for path in [name, "run.sh", "link"] {
            let entry = try XCTUnwrap(snapshot.entries.first { $0.path == path })
            try await repo.revertRepositoryBrowserFile(snapshot, entry: entry)
            let indexed = try await repo.run(["ls-files", "--stage", "--", path]).text
            XCTAssertTrue(indexed.hasPrefix(entry.mode + " " + entry.objectID + " 0\t"))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), binary)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("link").path), "old-target")
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("run.sh").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o111, 0o111)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let finalUnrelated = try await repo.run(["ls-files", "--stage", "--", "unrelated.txt"]).stdout
        XCTAssertEqual(finalHead, head); XCTAssertEqual(finalUnrelated, unrelated)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("unrelated.txt")), Data("unrelated staged".utf8))
    }
    func testRevertRejectsForeignFoldersSubmodulesBareAndEscapedAncestors() async throws {
        let (root, fixtureRepo, _) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_BROWSER_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixtureRepo.executable)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try Data("historical".utf8).write(to: root.appendingPathComponent("nested/file.txt"))
        try await repo.stage(["nested"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + head + ",module"])
        _ = try await repo.commit(message: "browser rejection fixture")
        let snapshot = try await repo.browseRepository()
        let nested = try await repo.browseRepositoryDirectory(snapshot, directory: "nested")
        let file = try XCTUnwrap(nested.entries.first)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let ordinary = try XCTUnwrap(snapshot.entries.first { $0.kind == .file })
        for invalid in ["--force", "HEAD", "", "1234"] {
            let forged = RepositoryBrowserSnapshot(root: snapshot.root, revision: snapshot.revision, objectID: invalid, treeID: snapshot.treeID, directory: snapshot.directory, bare: false, entries: snapshot.entries)
            do { try await repo.revertRepositoryBrowserFile(forged, entry: ordinary); XCTFail("Unpinned object accepted") } catch RepositoryBrowserFailure.selection {}
        }
        for entry in snapshot.entries.filter({ [.directory, .submodule].contains($0.kind) }) {
            do { try await repo.revertRepositoryBrowserFile(snapshot, entry: entry); XCTFail("Unsupported kind restored") } catch is RepositoryBrowserFailure {}
        }
        do { try await repo.revertRepositoryBrowserFile(snapshot, entry: file); XCTFail("Foreign entry restored") } catch is RepositoryBrowserFailure {}
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", "--", root.path, bareRoot.path])
        let bareRepo = GitRepository(root: bareRoot, executable: repo.executable), bare = try await bareRepo.browseRepository(directory: "nested")
        do { try await bareRepo.revertRepositoryBrowserFile(bare, entry: XCTUnwrap(bare.entries.first)); XCTFail("Bare restored") } catch is RepositoryBrowserFailure {}
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBrowserOutside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside must remain".utf8).write(to: outside.appendingPathComponent("file.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("nested"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("nested").path, withDestinationPath: outside.path)
        do { try await repo.revertRepositoryBrowserFile(nested, entry: file); XCTFail("Escaped ancestor restored") } catch is WorkingFileRestoreFailure {}
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file.txt")), Data("outside must remain".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testRevertLockFailureLeavesFileAndIndexUnchangedThenCanResume() async throws {
        let (root, fixtureRepo, _) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: ProcessInfo.processInfo.environment["TURTLEGIT_BROWSER_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixtureRepo.executable)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await repo.browseRepository()
        let entry = try XCTUnwrap(snapshot.entries.first { $0.kind == .file })
        let location = root.appendingPathComponent(entry.path), lock = root.appendingPathComponent(".git/index.lock")
        try Data("working stays on failure".utf8).write(to: location)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data().write(to: lock)
        do { try await repo.revertRepositoryBrowserFile(snapshot, entry: entry); XCTFail("Index lock ignored") } catch is GitFailure {}
        XCTAssertEqual(try Data(contentsOf: location), Data("working stays on failure".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        try FileManager.default.removeItem(at: lock)
        try await repo.revertRepositoryBrowserFile(snapshot, entry: entry)
        let original = try await repo.repositoryBrowserFile(snapshot, entry: entry)
        XCTAssertEqual(try Data(contentsOf: location), original.bytes)
    }
    func testExportPreservesPinnedRecursiveNamesBytesAndSkipsGitlinks() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = "folder 雪", nested = folder + "/nested", name = ":(glob)*\tline\n.bin"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(nested), withIntermediateDirectories: true)
        let binary = Data([0, 255, 13, 10])
        try binary.write(to: root.appendingPathComponent(nested + "/" + name))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(folder + "/link").path, withDestinationPath: "/outside/must-not-follow")
        try await repo.stage([folder])
        let previous = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + previous + "," + folder + "/module"])
        _ = try await repo.commit(message: "export old folder")
        let snapshot = try await repo.browseRepository()
        let entry = try XCTUnwrap(snapshot.entries.first { $0.path == folder })
        try Data("current must not export".utf8).write(to: root.appendingPathComponent(nested + "/" + name))
        try await repo.stage([folder]); _ = try await repo.commit(message: "advance export source")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let export = try await repo.exportRepositoryBrowser(snapshot, entry: entry)
        defer { export.discard() }
        XCTAssertEqual(export.item.lastPathComponent, folder); XCTAssertEqual(export.fileCount, 2)
        XCTAssertEqual(try Data(contentsOf: export.item.appendingPathComponent("nested/" + name)), binary)
        let link = export.item.appendingPathComponent("link")
        XCTAssertEqual(try Data(contentsOf: link), Data("/outside/must-not-follow".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType, .typeRegular)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.item.appendingPathComponent("module").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(nested + "/" + name)), Data("current must not export".utf8))
        let listing = try await repo.browseRepositoryDirectory(snapshot, directory: nested)
        let file = try XCTUnwrap(listing.entries.first)
        let single = try await repo.exportRepositoryBrowser(listing, entry: file)
        XCTAssertEqual(single.item.lastPathComponent, name); XCTAssertEqual(try Data(contentsOf: single.item), binary)
        single.discard(); XCTAssertFalse(FileManager.default.fileExists(atPath: single.directory.path))
        let directory = try await repo.exportRepositoryBrowser(listing)
        defer { directory.discard() }
        XCTAssertEqual(directory.item.lastPathComponent, "nested")
        XCTAssertEqual(try Data(contentsOf: directory.item.appendingPathComponent(name)), binary)
    }
    func testExportRejectsForeignGitlinkAndCancelledSelection() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + previous + ",module"])
        _ = try await repo.commit(message: "export gitlink rejection")
        let snapshot = try await repo.browseRepository(), module = try XCTUnwrap(snapshot.entries.first { $0.kind == .submodule })
        do { _ = try await repo.exportRepositoryBrowser(snapshot, entry: module); XCTFail("Gitlink exported as ordinary file") } catch is RepositoryBrowserFailure {}
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await repo.exportRepositoryBrowser(snapshot, cancellation: cancellation); XCTFail("Cancelled export continued") } catch is OperationCancellationFailure {}
        let file = try XCTUnwrap(snapshot.entries.first { $0.kind == .file })
        let foreign = RepositoryBrowserEntry(path: file.path, name: file.name, mode: file.mode, objectID: String(repeating: "f", count: 40), size: file.size)
        do { _ = try await repo.exportRepositoryBrowser(snapshot, entry: foreign); XCTFail("Foreign blob exported") } catch is RepositoryBrowserFailure {}
    }
    func testSortingAndMalformedTreeRecords() throws {
        let oid = String(repeating: "a", count: 40)
        let bytes = Data(("100644 blob " + oid + " 20\tfile2.txt\0" + "040000 tree " + oid + " -\tfolder\0" + "100644 blob " + oid + " 1\tfile10.txt\0").utf8)
        let entries = try RepositoryBrowserListing.parse(bytes, directory: "")
        XCTAssertEqual(RepositoryBrowserListing.sorted(entries).map(\.name), ["folder", "file2.txt", "file10.txt"])
        XCTAssertEqual(RepositoryBrowserListing.sorted(entries, descending: true).map(\.name), ["folder", "file10.txt", "file2.txt"])
        XCTAssertEqual(RepositoryBrowserListing.sorted(entries, by: .fileExtension).map(\.name), ["folder", "file10.txt", "file2.txt"])
        for malformed in ["100644 blob " + oid + " 3\tx", "100644 blob " + oid + " -\tx\0", "040000 blob " + oid + " -\tx\0", "100644 blob " + oid + " 3\t../x\0"] {
            XCTAssertThrowsError(try RepositoryBrowserListing.parse(Data(malformed.utf8), directory: ""))
        }
    }
}
