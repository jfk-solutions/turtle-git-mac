import XCTest
@testable import TurtleGitCore

final class DirectoryPatchTests: XCTestCase {
    func target(from root: URL, at target: URL) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["--old 雪", "delete", "binary", "other"] { try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: target.appendingPathComponent(name)) }
    }
    func testPlainDirectoryBinaryRenameSubsetAndEditedSave() async throws {
        let (source, _, bytes) = try await WorkingTreePatchReviewTests().fixture()
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitPlain-雪\n-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: plain) }
        try target(from: source, at: plain)
        let repo = GitRepository(root: plain)
        let review = try await repo.reviewWorkingTreePatch(bytes, directoryMode: true, isGitWorkingTree: false)
        XCTAssertTrue(review.canApply); XCTAssertFalse(review.isGitWorkingTree); XCTAssertEqual(review.files.count, 4)
        let binary = try XCTUnwrap(review.files.first { $0.path == "binary" })
        let subset = try await repo.reviewWorkingTreePatchFiles(review, fileIDs: [binary.id]); _ = try await repo.applyWorkingTreePatch(subset)
        XCTAssertEqual(try Data(contentsOf: plain.appendingPathComponent("binary")), Data([0,4,3,2,1,255]))
        let renamed = try XCTUnwrap(review.files.first { $0.path == "--new 雪" })
        let comparison = try await repo.compareWorkingTreePatchFile(review, fileID: renamed.id)
        XCTAssertEqual(comparison.document.base.bytes, Data("one\ntwo\nthree\nfour\n".utf8))
        let result = try await repo.saveWorkingTreePatchFile(comparison, text: "edited rename\n", autoAddNewFiles: true)
        XCTAssertNil(result.addError); XCTAssertFalse(result.output.contains("Added"))
        XCTAssertEqual(try Data(contentsOf: plain.appendingPathComponent("--new 雪")), Data("edited rename\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.appendingPathComponent("--old 雪").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.appendingPathComponent(".git").path))
        XCTAssertEqual(try Data(contentsOf: plain.appendingPathComponent("other")), Data("unrelated\n".utf8))
    }
    func testNestedGitFolderPathsAreAnchoredAndAutoAddUsesRealIndex() async throws {
        let (root, parent, bytes) = try await WorkingTreePatchReviewTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested 雪\n")
        try target(from: root, at: nested)
        let head = try await parent.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let repo = GitRepository(root: nested)
        let review = try await repo.reviewWorkingTreePatch(bytes, directoryMode: true, isGitWorkingTree: true)
        XCTAssertTrue(review.canApply); XCTAssertEqual(Set(review.files.map(\.path)), ["added", "binary", "delete", "--new 雪"])
        let selected = try await repo.reviewWorkingTreePatchFiles(review, fileIDs: Set(review.files.filter { $0.path != "added" }.map(\.id)))
        _ = try await repo.applyWorkingTreePatch(selected)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("binary")), Data([0,1,2,3,4]))
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent("binary")), Data([0,4,3,2,1,255]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let added = try XCTUnwrap(review.files.first { $0.path == "added" })
        let comparison = try await repo.compareWorkingTreePatchFile(review, fileID: added.id)
        let saved = try await repo.saveWorkingTreePatchFile(comparison, text: "new edited\n", autoAddNewFiles: true)
        XCTAssertNil(saved.addError)
        let names = try await parent.run(["diff", "--cached", "--name-only", "-z"]).stdout
        XCTAssertEqual(names, Data(("nested 雪\n/added\0").utf8))
        let afterHead = try await parent.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(afterHead, head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.appendingPathComponent(".git").path))
    }
    func testPlainDirectoryNewSaveNeverCreatesGitAndStaleInputsReject() async throws {
        let (source, _, bytes) = try await WorkingTreePatchReviewTests().fixture()
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitPlainSave-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: plain) }
        try target(from: source, at: plain)
        let repo = GitRepository(root: plain)
        let review = try await repo.reviewWorkingTreePatch(bytes, directoryMode: true, isGitWorkingTree: false)
        let added = try XCTUnwrap(review.files.first { $0.path == "added" })
        let comparison = try await repo.compareWorkingTreePatchFile(review, fileID: added.id)
        let saved = try await repo.saveWorkingTreePatchFile(comparison, text: "plain new file\n", autoAddNewFiles: true)
        XCTAssertNil(saved.addError); XCTAssertEqual(try Data(contentsOf: plain.appendingPathComponent("added")), Data("plain new file\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.appendingPathComponent(".git").path))
        try Data("external change\n".utf8).write(to: plain.appendingPathComponent("--old 雪"))
        do { _ = try await repo.applyWorkingTreePatch(review); XCTFail("Stale patch applied") } catch is GitFailure { }
        XCTAssertEqual(try Data(contentsOf: plain.appendingPathComponent("--old 雪")), Data("external change\n".utf8))
    }
    func testUnsafeDirectoryPathsAndWrongTargetReject() async throws {
        let (root, _, _) = try await WorkingTreePatchReviewTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        for path in ["../outside", ".git/config"] {
            let bytes = Data("diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1 @@\n+malicious\n".utf8)
            let review = try await repo.reviewWorkingTreePatch(bytes, directoryMode: true, isGitWorkingTree: true)
            XCTAssertFalse(review.canApply)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
    }
    func testFinderSinglePatchAndExtendedConditions() throws {
        XCTAssertTrue(FinderMenuEntry.applyPatch.availableInFinder)
        XCTAssertEqual(FinderMenuEntry.entry(for: .reviewPatch), .applyPatch)
        XCTAssertEqual(RepositoryAction.reviewPatch.icon, .patch)
        XCTAssertFalse(RepositoryAction.reviewPatch.requiresWorkingTree)
        XCTAssertTrue(FinderShellRules.allows(.reviewPatch, flags: [.patchFile, .onlyOne]))
        XCTAssertTrue(FinderShellRules.allows(.reviewPatch, flags: [.extended, .onlyOne]))
        XCTAssertFalse(FinderShellRules.allows(.reviewPatch, flags: [.patchFile, .two]))
        XCTAssertFalse(FinderShellRules.allows(.reviewPatch, flags: [.extended, .onlyOne, .folder]))
        let request = FinderRequest(action: .reviewPatch, paths: [URL(fileURLWithPath: "/outside 雪\n/a.patch")])
        XCTAssertEqual(try XCTUnwrap(request.url.flatMap(FinderRequest.init(url:))).paths, request.paths)
    }
}
