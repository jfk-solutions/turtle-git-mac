import XCTest
@testable import TurtleGitCore

final class SubmoduleUpdateTests: XCTestCase {
    private func fixture(two: Bool = false) async throws -> (URL, URL, GitRepository, GitRepository, String, String) {
        let (root, _, _) = try await GitPatchTests().fixture()
        let (source, remote, file) = try await GitPatchTests().fixture()
        let wrapper = root.appendingPathComponent("test-git-wrapper")
        try Data("#!/bin/sh\nexec /usr/bin/git -c protocol.file.allow=always \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let repo = GitRepository(root: root, executable: wrapper)
        let path = "group/module, 雪\n1"
        _ = try await repo.run(["submodule", "add", "--name", "first", "--", source.path, path])
        if two { _ = try await repo.run(["submodule", "add", "--name", "second", "--", source.path, "group-other/module2"]) }
        try await repo.stage([".gitmodules", path] + (two ? ["group-other/module2"] : [])); _ = try await repo.commit(message: "modules")
        return (root, source, repo, remote, path, file)
    }

    func testScopedSelectionLiteralPathsAndInitializationPreserveOtherModule() async throws {
        let (root, source, repo, _, path, _) = try await fixture(two: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let scoped = try await repo.submoduleUpdatePaths(scope: ["group"])
        XCTAssertEqual(scoped, [path])
        let exact = try await repo.submoduleUpdatePaths(scope: [path]); XCTAssertEqual(exact, [path])
        _ = try await repo.run(["submodule", "deinit", "-f", "--", path, "group-other/module2"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var options = SubmoduleUpdateOptions(); options.noFetch = true; options.initialize = false
        _ = try await repo.updateSubmodules(paths: scoped, options: options)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path + "/.git").path))
        options.initialize = true
        _ = try await repo.updateSubmodules(paths: scoped, options: options)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path + "/.git").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("group-other/module2/.git").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
        let child = GitRepository(root: root.appendingPathComponent(path), executable: repo.executable)
        let owner = try await child.discoverSelectionRoot(for: .submoduleUpdate, selected: child.root)
        XCTAssertEqual(owner, root.standardizedFileURL)
    }

    func testCheckoutAndForceHaveGitSemanticsWithoutMovingSuperprojectHead() async throws {
        let (root, source, repo, remote, path, file) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let child = GitRepository(root: root.appendingPathComponent(path), executable: repo.executable)
        let base = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("remote next\n".utf8).write(to: source.appendingPathComponent(file)); try await remote.stage([file]); _ = try await remote.commit(message: "remote next")
        _ = try await child.run(["fetch", "origin"])
        let next = try await remote.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--cacheinfo", "160000," + next + "," + path])
        let parentHead = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("local dirty bytes\n".utf8).write(to: child.root.appendingPathComponent(file))
        var options = SubmoduleUpdateOptions(); options.noFetch = true
        do { _ = try await repo.updateSubmodules(paths: [path], options: options); XCTFail("Overwrote dirty checkout without Force") } catch is GitFailure {}
        let unchanged = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(unchanged, base)
        XCTAssertEqual(try String(contentsOf: child.root.appendingPathComponent(file)), "local dirty bytes\n")
        options.force = true; _ = try await repo.updateSubmodules(paths: [path], options: options)
        let changed = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(changed, next)
        XCTAssertEqual(try String(contentsOf: child.root.appendingPathComponent(file)), "remote next\n")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, parentHead)
    }

    func testRemoteTrackingFetchAndNoFetchUseRequestedBranch() async throws {
        let (root, source, repo, remote, path, file) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let child = GitRepository(root: root.appendingPathComponent(path), executable: repo.executable)
        let base = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("remote next\n".utf8).write(to: source.appendingPathComponent(file)); try await remote.stage([file]); _ = try await remote.commit(message: "remote next")
        _ = try await repo.run(["config", "submodule.first.branch", "main"])
        var options = SubmoduleUpdateOptions(); options.remote = true; options.noFetch = true
        _ = try await repo.updateSubmodules(paths: [path], options: options)
        let beforeFetch = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(beforeFetch, base)
        options.noFetch = false; _ = try await repo.updateSubmodules(paths: [path], options: options)
        let changed = try await child.run(["rev-parse", "HEAD"]).stdout, expected = try await remote.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(changed, expected)
        let indexed = try await repo.run(["ls-files", "--stage", "--", path]).text; XCTAssertTrue(indexed.contains(base))
    }

    func testMergeAndRebaseRetainChildCommitsUsingDifferentHistories() async throws {
        for rebase in [false, true] {
            let (root, source, repo, remote, path, _) = try await fixture()
            defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
            let child = GitRepository(root: root.appendingPathComponent(path), executable: repo.executable)
            _ = try await child.run(["config", "user.name", "QA"]); _ = try await child.run(["config", "user.email", "qa@example.invalid"])
            _ = try await child.run(["switch", "-c", "local-work"])
            try Data("local addition\n".utf8).write(to: child.root.appendingPathComponent("local.txt")); try await child.stage(["local.txt"]); _ = try await child.commit(message: "local work")
            let local = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
            try Data("remote addition\n".utf8).write(to: source.appendingPathComponent("remote.txt")); try await remote.stage(["remote.txt"]); _ = try await remote.commit(message: "remote work")
            _ = try await child.run(["fetch", "origin"])
            let next = try await remote.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
            _ = try await repo.run(["update-index", "--cacheinfo", "160000," + next + "," + path])
            var options = SubmoduleUpdateOptions(); options.noFetch = true; options.merge = !rebase; options.rebase = rebase
            _ = try await repo.updateSubmodules(paths: [path], options: options)
            XCTAssertEqual(try String(contentsOf: child.root.appendingPathComponent("local.txt")), "local addition\n")
            XCTAssertEqual(try String(contentsOf: child.root.appendingPathComponent("remote.txt")), "remote addition\n")
            let parents = try await child.run(["rev-list", "--parents", "-n", "1", "HEAD"]).text.split(separator: " ")
            XCTAssertEqual(parents.count, rebase ? 2 : 3)
            if !rebase { XCTAssertTrue(parents.contains(Substring(local))) }
            _ = try await child.run(["merge-base", "--is-ancestor", next, "HEAD"])
        }
    }

    func testRecursiveInitializesNestedCheckoutOnlyWhenRequested() async throws {
        let (root, source, repo, remote, path, _) = try await fixture()
        let (nestedSource, _, nestedFile) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: nestedSource) }
        _ = try await remote.run(["-c", "protocol.file.allow=always", "submodule", "add", "--", nestedSource.path, "nested"])
        try await remote.stage([".gitmodules", "nested"]); _ = try await remote.commit(message: "nested module")
        let next = try await remote.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let child = GitRepository(root: root.appendingPathComponent(path), executable: repo.executable)
        _ = try await child.run(["fetch", "origin"])
        _ = try await repo.run(["update-index", "--cacheinfo", "160000," + next + "," + path])
        var options = SubmoduleUpdateOptions(); options.noFetch = true
        _ = try await repo.updateSubmodules(paths: [path], options: options)
        let nested = child.root.appendingPathComponent("nested")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.appendingPathComponent(".git").path))
        options.recursive = true
        _ = try await repo.updateSubmodules(paths: [path], options: options)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent(".git").path))
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent(nestedFile)), try Data(contentsOf: nestedSource.appendingPathComponent(nestedFile)))
    }

    func testInvalidSelectionsAndEscapingConfigPathsFailBeforeCheckout() async throws {
        let (root, source, repo, _, path, file) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let bytes = try Data(contentsOf: root.appendingPathComponent(path).appendingPathComponent(file))
        for selected in [[], [path, path], [path, "missing"]] {
            do { _ = try await repo.updateSubmodules(paths: selected, options: SubmoduleUpdateOptions()); XCTFail("Accepted invalid selection") } catch SubmoduleUpdateFailure.selection {}
        }
        _ = try await repo.run(["config", "-f", ".gitmodules", "submodule.escape.path", "../outside"])
        do { _ = try await repo.updateSubmodules(paths: [path], options: SubmoduleUpdateOptions()); XCTFail("Accepted escaping config") } catch WorkingFileRestoreFailure.location {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path).appendingPathComponent(file)), bytes)
    }
}
