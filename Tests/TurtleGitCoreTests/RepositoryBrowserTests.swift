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
