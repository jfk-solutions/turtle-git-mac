import XCTest
@testable import TurtleGitCore

final class WorkingTreeHistoryTests: XCTestCase {
    private var testGit: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_WORKING_ROW_TEST_GIT"] ?? "/usr/bin/git") }
    func testWorkingTreeRowUsesActualHeadAndRetainsLiteralChangesWithoutWritingIndex() async throws {
        let (root, _, path) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: testGit)
        defer { try? FileManager.default.removeItem(at: root) }
        let literal = ":(glob)* 雪\n.txt", renamed = "renamed\n雪.txt", binary = "binary", restored = "restored"
        try Data("one\n".utf8).write(to: root.appendingPathComponent(literal))
        try Data([0,1,2]).write(to: root.appendingPathComponent(binary))
        try Data("original\n".utf8).write(to: root.appendingPathComponent(restored))
        try await repo.stage([literal, binary, restored]); _ = try await repo.commit(message: "Working row base")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let cleanValue = try await repo.workingTreeHistory()
        let clean = try XCTUnwrap(cleanValue)
        XCTAssertEqual(clean.entry.hash, ""); XCTAssertEqual(clean.entry.parents, [head]); XCTAssertTrue(clean.files.isEmpty)
        _ = try await repo.run(["mv", "--", path, renamed])
        try Data("two\n".utf8).write(to: root.appendingPathComponent(literal)); try await repo.stage([literal])
        try Data("three\nfour\n".utf8).write(to: root.appendingPathComponent(literal))
        try Data([0,3,4]).write(to: root.appendingPathComponent(binary))
        // Net HEAD bytes can be clean while the index still contains a change.
        try Data("index change\n".utf8).write(to: root.appendingPathComponent(restored)); try await repo.stage([restored])
        try Data("original\n".utf8).write(to: root.appendingPathComponent(restored))
        let untracked = "untracked 雪\n", ignored = "ignored"
        try Data("keep\n".utf8).write(to: root.appendingPathComponent(untracked))
        try Data("ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("ignored bytes".utf8).write(to: root.appendingPathComponent(ignored))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let resultValue = try await repo.workingTreeHistory()
        let result = try XCTUnwrap(resultValue)
        XCTAssertEqual(result.entry.parents, [head]); XCTAssertEqual(Set(result.files.map(\.path)), [literal, renamed, binary, restored])
        let rename = try XCTUnwrap(result.files.first { $0.path == renamed }); XCTAssertEqual(rename.oldPath, path); XCTAssertTrue(rename.action.hasPrefix("R"))
        let text = try XCTUnwrap(result.files.first { $0.path == literal }); XCTAssertEqual(text.added, 2); XCTAssertEqual(text.removed, 1)
        let bin = try XCTUnwrap(result.files.first { $0.path == binary }); XCTAssertTrue(bin.hasStatistics); XCTAssertNil(bin.added); XCTAssertNil(bin.removed)
        XCTAssertTrue(result.files.contains { $0.path == restored && $0.status == "Modified" })
        XCTAssertEqual(Set(result.unversioned.map(\.path)), [untracked, ".gitignore"])
        XCTAssertTrue(result.unversioned.allSatisfy { $0.status == "Unversioned" })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(literal)), Data("three\nfour\n".utf8))
        let after = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(after, head)
        let rows = CommitGraph.layout([result.entry] + (try await repo.history()))
        XCTAssertTrue(rows[0].edges.contains { $0.startsAtNode }); XCTAssertTrue(rows[1].edges.contains { $0.endsAtNode })
    }

    func testUnbornBareCancellationAndCachedRemovalCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: testGit)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Working row QA"])
        _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("new\n".utf8).write(to: root.appendingPathComponent("new")); try await repo.stage(["new"])
        let unbornValue = try await repo.workingTreeHistory()
        let unborn = try XCTUnwrap(unbornValue); XCTAssertTrue(unborn.entry.parents.isEmpty)
        XCTAssertEqual(unborn.files.map(\.action), ["A"]); XCTAssertFalse(unborn.files[0].hasStatistics)
        do { _ = try await repo.workingTreeFileDiffData(files: unborn.files); XCTFail("Unborn unified diff accepted") } catch RevisionComparisonFailure.range {}
        _ = try await repo.commit(message: "First")
        _ = try await repo.run(["rm", "--cached", "--", "new"])
        let removedValue = try await repo.workingTreeHistory()
        let removed = try XCTUnwrap(removedValue)
        XCTAssertEqual(removed.files.map(\.action), ["D"]); XCTAssertEqual(removed.unversioned.map(\.path), ["new"])
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { _ = try await repo.workingTreeHistory(cancellation: cancelled); XCTFail("Cancelled read accepted") } catch { XCTAssertTrue(cancelled.isCancelled) }
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["init", "--bare", bareRoot.path])
        let bare = try await GitRepository(root: bareRoot, executable: testGit).workingTreeHistory(); XCTAssertNil(bare)
        do { _ = try await GitRepository(root: bareRoot, executable: testGit).workingTreeFileDiffData(files: removed.files); XCTFail("Bare working diff accepted") } catch RevisionComparisonFailure.range {}
    }
    func testConflictedRowPreservesUnmergedIndexAndActualHead() async throws {
        let (root, _, path) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: testGit)
        defer { try? FileManager.default.removeItem(at: root) }
        let branch = try await repo.branch()
        _ = try await repo.run(["checkout", "-b", "conflict-side"])
        try Data("side\n".utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "Side")
        _ = try await repo.run(["checkout", branch])
        try Data("main\n".utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "Main")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["merge", "--no-edit", "conflict-side"], successfulExitCodes: 0...1)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let stages = try await repo.run(["ls-files", "-u", "-z"]).stdout
        let bytes = try Data(contentsOf: root.appendingPathComponent(path))
        let value = try await repo.workingTreeHistory(), result = try XCTUnwrap(value)
        XCTAssertEqual(result.entry.parents, [head]); XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.status, "Conflicted")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        let after = try await repo.run(["ls-files", "-u", "-z"]).stdout; XCTAssertEqual(after, stages)
    }

    func testSubmoduleTypeSurvivesIndexDifferenceWithNetCleanWorkingPointer() async throws {
        let (root, _, _) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: testGit)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("module 雪")
        _ = try await repo.run(["init", "-b", "main", directory.path])
        let module = GitRepository(root: directory, executable: testGit)
        _ = try await module.run(["config", "user.name", "Module QA"])
        _ = try await module.run(["config", "user.email", "qa@example.invalid"])
        _ = try await module.run(["config", "commit.gpgsign", "false"])
        _ = try await module.run(["commit", "--allow-empty", "-m", "First module"])
        let first = try await module.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + first + ",module 雪"])
        _ = try await repo.commit(message: "Track gitlink")
        _ = try await module.run(["commit", "--allow-empty", "-m", "Second module"])
        try await repo.stage(["module 雪"])
        _ = try await module.run(["checkout", "--detach", first])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let value = try await repo.workingTreeHistory(), result = try XCTUnwrap(value)
        let file = try XCTUnwrap(result.files.first { $0.path == "module 雪" })
        XCTAssertTrue(file.isSubmodule); XCTAssertEqual(file.status, "Modified")
        XCTAssertFalse(file.hasStatistics)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let pointer = try await module.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(pointer, first)
    }

    func testSelectedWorkingPatchesPreserveRawBytesOrderRenamesAndIndex() async throws {
        let (root, _, path) = try await GitPatchTests().fixture()
        let repo = GitRepository(root: root, executable: testGit)
        defer { try? FileManager.default.removeItem(at: root) }
        let literal = ":(glob)* 雪\n.txt", other = "other.txt", renamed = "renamed 雪\n.txt"
        try Data([0xff, 10]).write(to: root.appendingPathComponent(literal))
        try Data("other base\n".utf8).write(to: root.appendingPathComponent(other))
        try await repo.stage([literal, other]); _ = try await repo.commit(message: "Patch bases")
        _ = try await repo.run(["mv", "--", path, renamed])
        try Data([0xfe, 10]).write(to: root.appendingPathComponent(literal)); try await repo.stage([literal])
        try Data([0xfd, 10]).write(to: root.appendingPathComponent(literal))
        try Data("UNSELECTED CONTENT\n".utf8).write(to: root.appendingPathComponent(other))
        _ = try await repo.run(["config", "diff.external", "/usr/bin/false"])
        _ = try await repo.run(["config", "diff.blocked.textconv", "/usr/bin/false"])
        try Data("*.txt diff=blocked\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let value = try await repo.workingTreeHistory(), snapshot = try XCTUnwrap(value)
        let text = try XCTUnwrap(snapshot.files.first { $0.path == literal })
        let rename = try XCTUnwrap(snapshot.files.first { $0.path == renamed })
        let patch = try await repo.workingTreeFileDiffData(files: [text, rename, text])
        let added = try XCTUnwrap(patch.range(of: Data([43, 0xfd, 10])))
        let moved = try XCTUnwrap(patch.range(of: Data("rename from ".utf8)))
        XCTAssertLessThan(added.lowerBound, moved.lowerBound)
        XCTAssertNil(patch.range(of: Data("UNSELECTED CONTENT".utf8)))
        XCTAssertNotNil(patch.range(of: Data([45, 0xff, 10])))
        XCTAssertNil(patch.range(of: Data([43, 0xfe, 10])))
        XCTAssertNil(patch.range(of: Data([43, 0xfd, 10]), in: added.upperBound..<patch.endIndex))
        let patchURL = root.appendingPathComponent(".git/selected-working.patch")
        try patch.write(to: patchURL)
        let alternativeIndex = root.appendingPathComponent(".git/working-qa.index").path
        _ = try await repo.run(["read-tree", "HEAD"], environmentOverrides: ["GIT_INDEX_FILE": alternativeIndex])
        _ = try await repo.run(["apply", "--cached", "--check", patchURL.path], environmentOverrides: ["GIT_INDEX_FILE": alternativeIndex])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(literal)), Data([0xfd, 10]))
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
        let untracked = try XCTUnwrap(snapshot.unversioned.first)
        do { _ = try await repo.workingTreeFileDiffData(files: [untracked]); XCTFail("Unversioned patch accepted") } catch RevisionComparisonFailure.selection {}
        do { _ = try await repo.workingTreeFileDiffData(files: []); XCTFail("Empty selection accepted") } catch RevisionComparisonFailure.selection {}
        let invalid = CommitFile(path: "../outside", oldPath: nil, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        do { _ = try await repo.workingTreeFileDiffData(files: [invalid]); XCTFail("Outside path accepted") } catch RevisionComparisonFailure.selection {}
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await repo.workingTreeFileDiffData(files: [text], cancellation: cancellation); XCTFail("Cancelled patch accepted") } catch { XCTAssertTrue(cancellation.isCancelled) }
    }

}
