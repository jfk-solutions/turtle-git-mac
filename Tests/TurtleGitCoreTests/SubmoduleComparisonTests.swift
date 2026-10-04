import XCTest
@testable import TurtleGitCore

final class SubmoduleComparisonTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository, GitRepository, String, String) {
        let (root, parent, _) = try await GitPatchTests().fixture()
        let path = ":(glob)* module, 雪\ncheckout"
        let location = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        let child = GitRepository(root: location)
        _ = try await child.run(["init", "-b", "main"])
        _ = try await child.run(["config", "user.name", "QA"])
        _ = try await child.run(["config", "user.email", "qa@example.invalid"])
        try Data("base\n".utf8).write(to: location.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "child base 雪")
        let hash = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await parent.run(["update-index", "--add", "--cacheinfo", "160000," + hash + "," + path])
        _ = try await parent.commit(message: "attach child")
        return (root, parent, child, path, hash)
    }

    func testWorkingComparisonUsesChildHeadAndDirtyStateWithoutWrites() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ignored.txt\n".utf8).write(to: child.root.appendingPathComponent(".git/info/exclude"))
        try Data("ignored local\n".utf8).write(to: child.root.appendingPathComponent("ignored.txt"))
        let owner = try await child.discoverSelectionRoot(for: .diff, selected: child.root)
        XCTAssertEqual(owner, parent.root)
        let childOwner = try await child.discoverSelectionRoot(for: .diff, selected: child.root.appendingPathComponent("file.txt"))
        XCTAssertEqual(childOwner, child.root)
        let clean = try await parent.submoduleComparison(path: path)
        XCTAssertEqual(clean.change, .identical); XCTAssertFalse(clean.dirty)
        XCTAssertEqual(clean.from.subject, "child base 雪"); XCTAssertEqual(clean.to.revision, base)
        try Data("next\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "child next")
        let next = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("staged\n".utf8).write(to: child.root.appendingPathComponent("file.txt")); try await child.stage(["file.txt"])
        try Data("later local\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try Data("untracked\n".utf8).write(to: child.root.appendingPathComponent("new.txt"))
        let parentIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let childIndex = try Data(contentsOf: child.root.appendingPathComponent(".git/index"))
        let parentHead = try await parent.run(["rev-parse", "HEAD"]).stdout
        let comparison = try await parent.submoduleComparison(path: path)
        XCTAssertEqual(comparison.change, .fastForward); XCTAssertTrue(comparison.dirty)
        XCTAssertEqual(comparison.from.revision, base); XCTAssertEqual(comparison.to.revision, next)
        XCTAssertTrue(comparison.from.canShowLog); XCTAssertTrue(comparison.to.canShowLog)
        XCTAssertTrue(comparison.toWorkingTree); XCTAssertEqual(comparison.checkout, child.root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), parentIndex)
        XCTAssertEqual(try Data(contentsOf: child.root.appendingPathComponent(".git/index")), childIndex)
        XCTAssertEqual(try String(contentsOf: child.root.appendingPathComponent("file.txt")), "later local\n")
        let after = try await parent.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, parentHead)
    }

    func testEmptyComparisonSidesAndReverseWorkingCheckout() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let added = try await parent.submoduleComparison(path: path, from: "", to: "HEAD")
        XCTAssertNil(added.from.revision); XCTAssertEqual(added.to.revision, base); XCTAssertEqual(added.change, .newSubmodule)
        let deleted = try await parent.submoduleComparison(path: path, from: "HEAD", to: "")
        XCTAssertEqual(deleted.from.revision, base); XCTAssertNil(deleted.to.revision); XCTAssertEqual(deleted.change, .deleteSubmodule)
        try Data("next\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "next")
        let next = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let reverse = try await parent.submoduleComparison(path: path, from: "Working tree", to: "HEAD")
        XCTAssertEqual(reverse.from.revision, next); XCTAssertEqual(reverse.to.revision, base); XCTAssertEqual(reverse.change, .rewind)
    }

    func testHistoricalGitlinksAreIndependentOfCheckoutAndCanRewind() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await parent.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("next\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "next")
        let next = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await parent.run(["update-index", "--cacheinfo", "160000," + next + "," + path]); _ = try await parent.commit(message: "advance child")
        _ = try await child.run(["checkout", "--detach", base])
        let rewind = try await parent.submoduleComparison(path: path)
        XCTAssertEqual(rewind.change, .rewind); XCTAssertEqual(rewind.from.revision, next); XCTAssertEqual(rewind.to.revision, base)
        try Data("untracked\n".utf8).write(to: child.root.appendingPathComponent("new.txt"))
        let historical = try await parent.submoduleComparison(path: path, from: before, to: "HEAD")
        XCTAssertEqual(historical.change, .fastForward); XCTAssertFalse(historical.dirty)
        XCTAssertFalse(historical.toWorkingTree); XCTAssertEqual(historical.from.revision, base); XCTAssertEqual(historical.to.revision, next)
        let unchanged = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(unchanged, base)
    }

    func testDivergentCommitTimesClassifyAllThreeCases() async throws {
        for (timestamp, expected) in [(1700000200, SubmoduleChangeType.newerTime), (1700000000, .olderTime), (1700000100, .sameTime)] {
            let (root, parent, child, path, base) = try await fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("left\n".utf8).write(to: child.root.appendingPathComponent("file.txt")); try await child.stage(["file.txt"])
            _ = try await child.run(["commit", "-m", "left"], environmentOverrides: ["GIT_AUTHOR_DATE":"1700000100 +0000", "GIT_COMMITTER_DATE":"1700000100 +0000"])
            let left = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
            _ = try await parent.run(["update-index", "--cacheinfo", "160000," + left + "," + path]); _ = try await parent.commit(message: "left child")
            _ = try await child.run(["checkout", "--detach", base])
            try Data("right\n".utf8).write(to: child.root.appendingPathComponent("file.txt")); try await child.stage(["file.txt"])
            _ = try await child.run(["commit", "-m", "right"], environmentOverrides: ["GIT_AUTHOR_DATE":"\(timestamp) +0000", "GIT_COMMITTER_DATE":"\(timestamp) +0000"])
            let comparison = try await parent.submoduleComparison(path: path)
            XCTAssertEqual(comparison.change, expected); XCTAssertEqual(comparison.from.subject, "left"); XCTAssertEqual(comparison.to.subject, "right")
        }
    }

    func testUninitializedAndMissingObjectsDisableMetadataAndLog() async throws {
        let (root, parent, child, path, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: child.root)
        try FileManager.default.createDirectory(at: child.root, withIntermediateDirectories: false)
        let uninitialized = try await parent.submoduleComparison(path: path)
        XCTAssertNil(uninitialized.checkout); XCTAssertFalse(uninitialized.dirty); XCTAssertEqual(uninitialized.change, .unknown)
        XCTAssertFalse(uninitialized.from.canShowLog); XCTAssertFalse(uninitialized.to.canShowLog)
        XCTAssertEqual(uninitialized.from.subject, "not initialized")
        _ = try await child.run(["init", "-b", "main"])
        try Data("other\n".utf8).write(to: child.root.appendingPathComponent("other.txt")); try await child.stage(["other.txt"])
        _ = try await child.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "unrelated child"])
        let missing = try await parent.submoduleComparison(path: path)
        XCTAssertEqual(missing.change, .unknown); XCTAssertFalse(missing.from.available)
        XCTAssertTrue(missing.to.available); XCTAssertTrue(missing.to.canShowLog)
    }

    func testAdditionDeletionAndUnsupportedOrEscapingPaths() async throws {
        let (root, parent, child, path, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyTree = try await parent.run(["mktree"]).text.trimmingCharacters(in: .newlines)
        let initial = try await parent.submoduleComparison(path: path, from: emptyTree)
        XCTAssertEqual(initial.change, .newSubmodule)
        let added = try await parent.submoduleComparison(path: path, from: "HEAD^")
        XCTAssertEqual(added.change, .newSubmodule); XCTAssertNil(added.from.revision); XCTAssertFalse(added.from.canShowLog)
        let attached = try await parent.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await parent.run(["update-index", "--force-remove", "--", path]); _ = try await parent.commit(message: "remove child")
        let deleted = try await parent.submoduleComparison(path: path, from: attached, to: "HEAD")
        XCTAssertEqual(deleted.change, .deleteSubmodule); XCTAssertNil(deleted.to.revision); XCTAssertFalse(deleted.to.canShowLog)
        do { _ = try await parent.submoduleComparison(path: "../escape"); XCTFail("Accepted outside path") } catch WorkingFileRestoreFailure.location {}
        do { _ = try await parent.submoduleComparison(path: "not a module"); XCTFail("Accepted unrelated path") } catch SubmoduleComparisonFailure.unsupported {}
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: child.root, to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: child.root, withDestinationURL: outside)
        do { _ = try await parent.submoduleComparison(path: path, from: attached); XCTFail("Followed external checkout symlink") } catch SubmoduleComparisonFailure.unsafeCheckout {}
    }

    func testRevertResultPinsComparisonBeforeLaterSuperprojectCommit() async throws {
        let (root, parent, child, path, base) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("advanced\n".utf8).write(to: child.root.appendingPathComponent("file.txt"))
        try await child.stage(["file.txt"]); _ = try await child.commit(message: "advanced child")
        let next = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let selected = try await parent.status().filter { $0.path == path }
        let result = try await parent.revertWorkingFiles(selected)
        XCTAssertEqual(result.submodulePaths, [path]); XCTAssertTrue(result.trashedFiles.isEmpty)
        _ = try await parent.run(["update-index", "--cacheinfo", "160000," + next + "," + path]); _ = try await parent.commit(message: "later superproject commit")
        let comparison = try await parent.submoduleComparison(path: path, from: result.comparisonRevision)
        XCTAssertEqual(comparison.from.revision, base); XCTAssertEqual(comparison.to.revision, next)
        XCTAssertEqual(comparison.change, .fastForward)
        let current = try await parent.submoduleComparison(path: path); XCTAssertEqual(current.change, .identical)
    }

    func testConflictedIndexUsesConflictWorkflow() async throws {
        let (root, source, parent, _, path) = try await ConflictResolutionTests().submoduleFixture(initialized: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        do { _ = try await parent.submoduleComparison(path: path); XCTFail("Accepted unresolved index") } catch SubmoduleComparisonFailure.conflicted {}
    }
}
