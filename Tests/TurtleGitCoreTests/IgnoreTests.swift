import XCTest
@testable import TurtleGitCore

final class IgnoreTests: XCTestCase {
    func testAllScopeAndDestinationCombinationsHaveRealGitSemanticsAndKeepIndex() async throws {
        for destination in IgnoreDestination.allCases {
            for scope in IgnoreScope.allCases {
                let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
                defer { try? FileManager.default.removeItem(at: root) }
                for folder in ["a/deep", "b/deep"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
                for path in ["a/item.tmp", "a/deep/item.tmp", "b/item.tmp"] { try helper.write(root, path, "local\n") }
                let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
                var options = try IgnoreOptions(paths: ["a/item.tmp"]); options.scope = scope; options.destination = destination
                let changed = try await repo.addIgnoreRules(options)
                XCTAssertEqual(changed.count, 1)
                let selectedIgnored = try await ignored(repo, "a/item.tmp"); XCTAssertTrue(selectedIgnored)
                let recursive = scope == .recursively
                let descendantIgnored = try await ignored(repo, "a/deep/item.tmp"); XCTAssertEqual(descendantIgnored, recursive)
                let siblingIgnored = try await ignored(repo, "b/item.tmp"); XCTAssertEqual(siblingIgnored, recursive && destination != .containingFolders)
                let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout
                XCTAssertEqual(index, after)
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a/item.tmp")), "local\n")
                if destination == .exclude { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path)) }
            }
        }
    }
    func testAppendRetainsExistingCRLFCommentsPermissionsAndAvoidsDuplicates() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".gitignore")
        try Data("\u{feff}# existing\r\nold\r\n# no final newline".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let options = try IgnoreOptions(paths: ["first.tmp", "second.tmp", "first.tmp"])
        _ = try await repo.addIgnoreRules(options)
        XCTAssertEqual(try Data(contentsOf: file), Data("\u{feff}# existing\r\nold\r\n# no final newline\r\n/first.tmp\r\n/second.tmp\r\n".utf8))
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        let second = try await repo.addIgnoreRules(options)
        XCTAssertTrue(second.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o640)
        XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, inode)
    }
    func testMacLiteralNamesAndExtensionMasksDoNotBroadenRules() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["literal*.tmp", "literal?.tmp", "bracket[1].tmp", "back\\slash.tmp", "#hash.tmp", "!bang.tmp", "space.tmp ", "雪.tmp"]
        for name in names + ["literalX.tmp", "bracket1.tmp", "space.tmp"] { try helper.write(root, name, "local\n") }
        _ = try await repo.addIgnoreRules(IgnoreOptions(paths: names))
        for name in names { let value = try await ignored(repo, name); XCTAssertTrue(value, name) }
        for name in ["literalX.tmp", "bracket1.tmp", "space.tmp"] { let value = try await ignored(repo, name); XCTAssertFalse(value, name) }
        var mask = try IgnoreOptions(paths: ["extensionless", "a.txt", "b.txt", "c.swift"], mask: true); mask.scope = .recursively
        _ = try await repo.addIgnoreRules(mask)
        let rules = try String(contentsOf: root.appendingPathComponent(".gitignore"))
        XCTAssertEqual(rules.components(separatedBy: "\n").filter { $0 == "*.txt" }.count, 1)
        let deep = try await ignored(repo, "deep/new.txt"); XCTAssertTrue(deep)
        let extensionless = try await ignored(repo, "extensionless"); XCTAssertFalse(extensionless)
    }
    func testContainingDestinationsValidateAllFilesBeforeWritingAndRejectUnsafePaths() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["one", "two", "nested"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("untouched\n".utf8).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("two/.gitignore"), withDestinationURL: outside)
        var options = try IgnoreOptions(paths: ["one/file", "two/file"]); options.destination = .containingFolders
        do { _ = try await repo.addIgnoreRules(options); XCTFail("Accepted symbolic ignore file") } catch IgnoreFailure.unsupportedFile {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("one/.gitignore").path))
        XCTAssertEqual(try String(contentsOf: outside), "untouched\n")
        for path in [".", "../outside", ".git/config", "x/.GIT/info", "line\nbreak", "line\rbreak"] { XCTAssertThrowsError(try IgnoreOptions(paths: [path])) }
        _ = try await GitRepository(root: root.appendingPathComponent("nested")).run(["init"])
        do { _ = try await repo.addIgnoreRules(IgnoreOptions(paths: ["nested/file"])); XCTFail("Accepted nested repository") } catch IgnoreFailure.outsideWorkingTree {}
        let invalid = root.appendingPathComponent(".gitignore")
        try Data([0xff]).write(to: invalid)
        do { _ = try await repo.addIgnoreRules(IgnoreOptions(paths: ["file"])); XCTFail("Rewrote invalid encoding") } catch IgnoreFailure.unsupportedFile {}
        XCTAssertEqual(try Data(contentsOf: invalid), Data([0xff]))
        let externalInfo = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: externalInfo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalInfo) }
        try FileManager.default.moveItem(at: root.appendingPathComponent(".git/info"), to: root.appendingPathComponent(".git/info-backup"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".git/info"), withDestinationURL: externalInfo)
        var exclude = try IgnoreOptions(paths: ["file"]); exclude.destination = .exclude
        do { _ = try await repo.addIgnoreRules(exclude); XCTFail("Wrote through external info symlink") } catch IgnoreFailure.outsideWorkingTree {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalInfo.appendingPathComponent("exclude").path))
    }
    func testLinkedWorktreeExcludeUsesCommonGitDirectoryAndTrackedKeepLocalComposition() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "tracked.txt", "base\n"); try await repo.stage(["tracked.txt"]); _ = try await repo.commit(message: "base")
        let worktree = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: worktree) }
        _ = try await repo.run(["worktree", "add", "-b", "linked", worktree.path])
        let linked = GitRepository(root: worktree)
        var options = try IgnoreOptions(paths: ["tracked.txt"]); options.destination = .exclude
        let destinations = try await linked.ignoreDestinations(options)
        XCTAssertEqual(destinations.first?.standardizedFileURL, root.appendingPathComponent(".git/info/exclude").standardizedFileURL)
        _ = try await linked.addIgnoreRules(options)
        _ = try await linked.removeVersionedPath("tracked.txt", keepLocal: true)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("tracked.txt")), "base\n")
        let retained = try await ignored(linked, "tracked.txt"); XCTAssertTrue(retained)
        let status = try await linked.status()
        XCTAssertTrue(status.contains { $0.path == "tracked.txt" && $0.index == "D" && $0.hasUnversionedCopy })
    }
    func testCachedFinderConditionsAndBareRepositories() async throws {
        let root = URL(fileURLWithPath: "/fixture")
        let snapshot = FinderSnapshot.build(root: root, tracked: ["tracked.txt"], changes: [StatusEntry(path: "new.txt", originalPath: nil, index: "?", worktree: "?"), StatusEntry(path: "ignored.txt", originalPath: nil, index: "!", worktree: "!")])
        XCTAssertTrue(snapshot.canIgnore([root.appendingPathComponent("new.txt")], deleting: false))
        XCTAssertFalse(snapshot.canIgnore([root.appendingPathComponent("tracked.txt")], deleting: false))
        XCTAssertTrue(snapshot.canIgnore([root.appendingPathComponent("tracked.txt")], deleting: true))
        for selection in [[], [root], [root.appendingPathComponent("ignored.txt")], [root.appendingPathComponent("new.txt"), URL(fileURLWithPath: "/other/file")]] {
            XCTAssertFalse(snapshot.canIgnore(selection, deleting: false))
            XCTAssertFalse(snapshot.canIgnore(selection, deleting: true))
        }
        let helper = CommitSelectionTests(), (folder, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await repo.run(["config", "core.bare", "true"])
        do { _ = try await repo.addIgnoreRules(IgnoreOptions(paths: ["file.txt"])); XCTFail("Accepted bare repository") } catch IgnoreFailure.selection {}
    }
    private func ignored(_ repository: GitRepository, _ path: String) async throws -> Bool {
        do { _ = try await repository.run(["check-ignore", "--no-index", "--", path], literalPathspecs: false); return true }
        catch let failure as GitFailure where failure.code == 1 { return false }
    }
}
