import XCTest
@testable import TurtleGitCore

final class ConflictResolutionTests: XCTestCase {
    func fixture(deletedMine: Bool = false, binary: Bool = false, deletedTheirs: Bool = false) async throws -> (URL, GitRepository, String) {
        let (root, repo) = try await CommitSelectionTests().fixture()
        let path = "-conflict 雪\n[*].txt"
        func write(_ text: String) throws { try Data(((binary ? "\0" : "") + text).utf8).write(to: root.appendingPathComponent(path)) }
        try write("base\n"); try Data("base other\n".utf8).write(to: root.appendingPathComponent("other.txt"))
        try await repo.stage([path, "other.txt"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["checkout", "-b", "side"])
        if deletedTheirs { _ = try await repo.run(["rm", "--", path]) }
        else { try write("theirs\n"); try await repo.stage([path]) }
        _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["checkout", "main"])
        if deletedMine { _ = try await repo.run(["rm", "--", path]) }
        else { try write("mine\n"); try await repo.stage([path]) }
        _ = try await repo.commit(message: "mine")
        do { _ = try await repo.run(["merge", "--no-edit", "side"]); XCTFail("Expected conflict") } catch is GitFailure {}
        try Data("other index\n".utf8).write(to: root.appendingPathComponent("other.txt")); try await repo.stage(["other.txt"])
        try Data("other working\n".utf8).write(to: root.appendingPathComponent("other.txt"))
        return (root, repo, path)
    }
    func testCurrentResolutionKeepsWorkingContentsAndUnrelatedIndexAndDoesNotCommit() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let checked = try await repo.conflicts(), head = try await repo.run(["rev-parse", "HEAD"]).text
        try Data("manually resolved\n".utf8).write(to: root.appendingPathComponent(path))
        _ = try await repo.resolveConflicts(checked, using: .current)
        let remaining = try await repo.conflicts(), after = try await repo.run(["rev-parse", "HEAD"]).text
        let index = try await repo.run(["show", ":" + path]).text, other = try await repo.run(["show", ":other.txt"]).text
        XCTAssertTrue(remaining.isEmpty); XCTAssertEqual(head, after); XCTAssertEqual(index, "manually resolved\n"); XCTAssertEqual(other, "other index\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "other working\n")
        _ = try await repo.run(["rev-parse", "--verify", "MERGE_HEAD"])
    }
    func testMineTheirsAndBinaryResolutionSelectExactStageWithoutChangingOtherFiles() async throws {
        for binary in [false, true] {
            for choice in [ResolveChoice.mine, .theirs] {
                let (root, repo, path) = try await fixture(binary: binary); defer { try? FileManager.default.removeItem(at: root) }
                let checked = try await repo.conflicts(); XCTAssertEqual(checked.first?.stages.map(\.number), [1, 2, 3])
                let expected = try await repo.run(["cat-file", "blob", checked[0].stages.first { $0.number == choice.rawValue }!.object]).stdout
                _ = try await repo.resolveConflicts(checked, using: choice)
                let indexed = try await repo.run(["show", ":" + path]).stdout, other = try await repo.run(["show", ":other.txt"]).text
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), expected); XCTAssertEqual(indexed, expected); XCTAssertEqual(other, "other index\n")
                let remaining = try await repo.conflicts(); XCTAssertTrue(remaining.isEmpty)
            }
        }
    }
    func testModifyDeleteUsesAbsentStageAsDeletionAndPresentStageAsRestoration() async throws {
        for choice in [ResolveChoice.mine, .theirs, .current] {
            let (root, repo, path) = try await fixture(deletedMine: true); defer { try? FileManager.default.removeItem(at: root) }
            let checked = try await repo.conflicts(); XCTAssertNil(checked[0].stages.first { $0.number == 2 })
            if choice == .current { try FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
            _ = try await repo.resolveConflicts(checked, using: choice)
            let names = try await repo.trackedPaths(), remaining = try await repo.conflicts()
            XCTAssertTrue(remaining.isEmpty); XCTAssertEqual(names.contains(path), choice == .theirs)
            XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), choice == .theirs)
        }
    }
    func testStaleSnapshotAndInvalidScopesRejectBeforeMutating() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await repo.conflicts()
        let bytes = try Data(contentsOf: root.appendingPathComponent(path))
        _ = try await repo.resolveConflicts(snapshot, using: .mine)
        let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout, mine = try Data(contentsOf: root.appendingPathComponent(path))
        do { _ = try await repo.resolveConflicts(snapshot, using: .theirs); XCTFail("Accepted stale stages") } catch ResolveFailure.stale {}
        let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(index, after); XCTAssertEqual(mine, try Data(contentsOf: root.appendingPathComponent(path))); XCTAssertNotEqual(bytes, mine)
        for scopes in [["../outside"], [".git/config"], ["bad\0path"]] { do { _ = try await repo.conflicts(paths: scopes); XCTFail("Accepted invalid scope") } catch ResolveFailure.outsideWorkingTree {} }
        do { _ = try await repo.resolveConflicts([], using: .current); XCTFail("Accepted empty selection") } catch ResolveFailure.selection {}
    }
    func testFolderScopeResolvesOnlyCheckedConflictAndCachedFinderUsesBoundaries() async throws {
        let (root, repo) = try await CommitSelectionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["folder/file.txt", "folder-other/file.txt"]
        for path in paths { try FileManager.default.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true); try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(paths); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["checkout", "-b", "side"])
        for path in paths { try Data("theirs\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(paths); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["checkout", "main"])
        for path in paths { try Data("mine\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(paths); _ = try await repo.commit(message: "mine")
        do { _ = try await repo.run(["merge", "side"]); XCTFail("Expected conflicts") } catch is GitFailure {}
        let scoped = try await repo.conflicts(paths: ["folder"]); XCTAssertEqual(scoped.map(\.path), [paths[0]])
        _ = try await repo.resolveConflicts(scoped, using: .mine)
        let remaining = try await repo.conflicts(); XCTAssertEqual(remaining.map(\.path), [paths[1]])
        let snapshot = FinderSnapshot.build(root: root, tracked: paths, changes: try await repo.status())
        XCTAssertTrue(snapshot.canResolve([root]))
        XCTAssertTrue(snapshot.canResolve([root.appendingPathComponent("folder-other")]))
        XCTAssertFalse(snapshot.canResolve([root.appendingPathComponent("folder")]))
        XCTAssertFalse(snapshot.canResolve([root, URL(fileURLWithPath: "/outside")]))
    }
    func testSymlinkConflictKeepsExternalTargetsUntouched() async throws {
        let (root, repo) = try await CommitSelectionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: outside) }
        for name in ["base", "mine", "theirs"] { try Data((name + "\n").utf8).write(to: outside.appendingPathComponent(name)) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent("base")); try await repo.stage(["link"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["checkout", "-b", "side"])
        try FileManager.default.removeItem(at: link); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent("theirs")); try await repo.stage(["link"]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["checkout", "main"])
        try FileManager.default.removeItem(at: link); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent("mine")); try await repo.stage(["link"]); _ = try await repo.commit(message: "mine")
        do { _ = try await repo.run(["merge", "side"]); XCTFail("Expected symlink conflict") } catch is GitFailure {}
        _ = try await repo.resolveConflicts(try await repo.conflicts(), using: .theirs)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.appendingPathComponent("theirs").path)
        for name in ["base", "mine", "theirs"] { XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent(name)), name + "\n") }
    }
    func testRebaseStageMappingAndFolderScope() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", "other.txt"])
        _ = try await repo.run(["merge", "--abort"])
        _ = try await repo.run(["reset", "--hard", "HEAD"])
        do { _ = try await repo.run(["rebase", "side"]); XCTFail("Expected rebase conflict") } catch is GitFailure {}
        let rebase = try await repo.conflictIsRebase(); XCTAssertTrue(rebase)
        let entries = try await repo.conflicts(paths: [path]), absent = try await repo.conflicts(paths: ["unrelated"])
        XCTAssertEqual(entries.count, 1); XCTAssertTrue(absent.isEmpty)
        let stage = entries[0].stages.first { $0.number == 2 }!
        let expected = try await repo.run(["cat-file", "blob", stage.object]).stdout
        _ = try await repo.resolveConflicts(entries, using: .mine)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), expected)
        _ = try await repo.run(["rebase", "--abort"])
    }
    func testExecutableSideRestoresBlobAndModeWithFileModeEnabled() async throws {
        for choice in [ResolveChoice.mine, .theirs] {
            let (root, repo) = try await CommitSelectionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
            _ = try await repo.run(["config", "core.filemode", "true"])
            let file = root.appendingPathComponent("run.sh")
            try Data("base\n".utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try await repo.stage(["run.sh"]); _ = try await repo.commit(message: "base")
            _ = try await repo.run(["checkout", "-b", "side"])
            try Data("theirs\n".utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            try await repo.stage(["run.sh"]); _ = try await repo.commit(message: "theirs executable")
            _ = try await repo.run(["checkout", "main"])
            try Data("mine\n".utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try await repo.stage(["run.sh"]); _ = try await repo.commit(message: "mine nonexecutable")
            do { _ = try await repo.run(["merge", "side"]); XCTFail("Expected conflict") } catch is GitFailure {}
            let checked = try await repo.conflicts(), stage = checked[0].stages.first { $0.number == choice.rawValue }!
            XCTAssertEqual(stage.mode, choice == .mine ? "100644" : "100755")
            _ = try await repo.resolveConflicts(checked, using: choice)
            let indexed = try await repo.run(["ls-files", "--stage", "--", "run.sh"]).text
            XCTAssertTrue(indexed.hasPrefix(stage.mode + " " + stage.object + " 0\t"))
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(mode.intValue & 0o111, choice == .mine ? 0 : 0o111)
            XCTAssertEqual(try String(contentsOf: file), choice == .mine ? "mine\n" : "theirs\n")
        }
    }
    func submoduleFixture(initialized: Bool) async throws -> (URL, URL, GitRepository, GitRepository?, String) {
        let (root, repo) = try await CommitSelectionTests().fixture()
        let (source, child) = try await CommitSelectionTests().fixture()
        let path = "module, 雪"
        let file = source.appendingPathComponent("file.txt")
        try Data("base\n".utf8).write(to: file); try await child.stage(["file.txt"]); _ = try await child.commit(message: "base")
        let base = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await child.run(["checkout", "-b", "side"])
        try Data("theirs\n".utf8).write(to: file); try await child.stage(["file.txt"]); _ = try await child.commit(message: "theirs")
        let theirs = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await child.run(["checkout", "main"])
        try Data("mine\n".utf8).write(to: file); try await child.stage(["file.txt"]); _ = try await child.commit(message: "mine")
        let mine = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        if initialized { _ = try await repo.run(["clone", "--no-local", "--", source.path, path]) }
        else { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + base + "," + path]); _ = try await repo.commit(message: "base module")
        _ = try await repo.run(["checkout", "-b", "side"])
        _ = try await repo.run(["update-index", "--cacheinfo", "160000," + theirs + "," + path]); _ = try await repo.commit(message: "theirs module")
        _ = try await repo.run(["checkout", "main"])
        _ = try await repo.run(["update-index", "--cacheinfo", "160000," + mine + "," + path]); _ = try await repo.commit(message: "mine module")
        do { _ = try await repo.run(["merge", "side"]); XCTFail("Expected submodule conflict") } catch is GitFailure {}
        return (root, source, repo, initialized ? GitRepository(root: root.appendingPathComponent(path)) : nil, path)
    }
    func testUninitializedSubmoduleSidesResolveExactGitlinkWithoutCreatingCheckout() async throws {
        for choice in [ResolveChoice.mine, .theirs] {
            let (root, source, repo, _, path) = try await submoduleFixture(initialized: false)
            defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
            let checked = try await repo.conflicts(), head = try await repo.run(["rev-parse", "HEAD"]).stdout
            XCTAssertEqual(checked.count, 1); XCTAssertTrue(checked[0].isSubmodule)
            let target = checked[0].stages.first { $0.number == choice.rawValue }!
            _ = try await repo.resolveConflicts(checked, using: choice)
            let indexed = try await repo.run(["ls-files", "--stage", "-z", "--", path]).text
            XCTAssertEqual(indexed, "160000 " + target.object + " 0\t" + path + "\0")
            let remaining = try await repo.conflicts(), after = try await repo.run(["rev-parse", "HEAD"]).stdout
            XCTAssertTrue(remaining.isEmpty); XCTAssertEqual(head, after)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(path).path).isEmpty)
        }
    }
    func testInitializedSubmoduleRejectsDifferentCheckoutThenResolvesMatchingSide() async throws {
        let (root, source, repo, optionalChild, path) = try await submoduleFixture(initialized: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let child = try XCTUnwrap(optionalChild), checked = try await repo.conflicts()
        let owner = try await child.discoverSelectionRoot(for: .resolveTheirs, selected: child.root)
        let childOwner = try await child.discoverSelectionRoot(for: .status, selected: child.root)
        let fileOwner = try await child.discoverSelectionRoot(for: .resolve, selected: child.root.appendingPathComponent("file.txt"))
        XCTAssertEqual(owner, root.standardizedFileURL); XCTAssertEqual(childOwner, child.root); XCTAssertEqual(fileOwner, child.root)
        let resetTarget = try await repo.submoduleResetTarget(checked[0], using: .theirs)
        XCTAssertEqual(resetTarget.0.standardizedFileURL, child.root)
        XCTAssertEqual(resetTarget.1, checked[0].stages.first { $0.number == 3 }?.object)
        let before = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let childHead = try await child.run(["rev-parse", "HEAD"]).stdout
        let contents = try Data(contentsOf: child.root.appendingPathComponent("file.txt"))
        do { _ = try await repo.resolveConflicts(checked, using: .theirs); XCTFail("Accepted different submodule checkout") }
        catch ResolveFailure.submoduleCheckout(let failedPath) { XCTAssertEqual(failedPath, path) }
        let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout, afterHead = try await child.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(before, after); XCTAssertEqual(childHead, afterHead); XCTAssertEqual(contents, try Data(contentsOf: child.root.appendingPathComponent("file.txt")))
        let target = checked[0].stages.first { $0.number == 3 }!
        _ = try await child.run(["checkout", "--detach", target.object])
        _ = try await repo.resolveConflicts(checked, using: .theirs)
        let indexed = try await repo.run(["ls-files", "--stage", "-z", "--", path]).text
        XCTAssertEqual(indexed, "160000 " + target.object + " 0\t" + path + "\0")
        XCTAssertEqual(try String(contentsOf: child.root.appendingPathComponent("file.txt")), "theirs\n")
    }

}
