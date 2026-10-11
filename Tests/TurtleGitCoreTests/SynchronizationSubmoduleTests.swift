import XCTest
@testable import TurtleGitCore

final class SynchronizationSubmoduleTests: XCTestCase {
    private struct Fixture {
        let directory: URL, git: URL
        let client: GitRepository, middle: GitRepository, leaf: GitRepository
        let middleBase: String, middleTarget: String, leafTarget: String
        let middlePath = "modules/middle 雪", leafPath = "nested leaf"
    }
    private func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func hash(_ repo: GitRepository, _ ref: String = "HEAD") async throws -> String {
        try await repo.run(["rev-parse", "--verify", ref]).text.trimmingCharacters(in: .newlines)
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-sync-submodules-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var fixtureReady = false
        defer { if !fixtureReady { try? FileManager.default.removeItem(at: directory) } }
        let selected = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/git")
        // Only this private fixture permits its local file remotes. Propagate the
        // selected packaged engine's runtime environment through the test shim.
        let git = directory.appendingPathComponent("git-fixture")
        let environment = GitRuntime.environment(executable: selected).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quoted($0.value) }.joined(separator: "\n")
        try Data(("#!/bin/sh\n" + environment + "\nexec " + quoted(selected.path) + " -c protocol.file.allow=always \"$@\"\n").utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: git.path)
        let parent = GitRepository(root: directory, executable: git)
        func create(_ name: String) async throws -> GitRepository {
            let repo = GitRepository(root: directory.appendingPathComponent(name), executable: git)
            _ = try await parent.run(["init", "-b", "main", "--template=", repo.root.path])
            for (key, value) in [("user.name", "Submodule QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
            return repo
        }
        func commit(_ repo: GitRepository, _ message: String) async throws -> String {
            _ = try await repo.run(["add", "--all"]); _ = try await repo.run(["commit", "-m", message]); return try await hash(repo)
        }
        let leafSource = try await create("leaf source"), middleSource = try await create("middle source"), author = try await create("top author")
        try Data("leaf base\n".utf8).write(to: leafSource.root.appendingPathComponent("leaf.txt"))
        let leafBase = try await commit(leafSource, "leaf base")
        try Data("leaf target\n".utf8).write(to: leafSource.root.appendingPathComponent("leaf.txt"))
        let leafTarget = try await commit(leafSource, "leaf target")
        _ = try await leafSource.run(["checkout", "--detach", leafBase])
        _ = try await middleSource.run(["submodule", "add", "--name", "leaf-雪", "--", leafSource.root.path, "nested leaf"])
        try Data("middle base\n".utf8).write(to: middleSource.root.appendingPathComponent("middle.txt"))
        let middleBase = try await commit(middleSource, "middle base")
        let middleLeaf = GitRepository(root: middleSource.root.appendingPathComponent("nested leaf"), executable: git)
        _ = try await middleLeaf.run(["checkout", "--detach", leafTarget])
        try Data("middle target\n".utf8).write(to: middleSource.root.appendingPathComponent("middle.txt"))
        let middleTarget = try await commit(middleSource, "middle and nested target")
        _ = try await middleSource.run(["checkout", "--detach", middleBase])
        _ = try await author.run(["submodule", "add", "--name", "mid-雪", "--", middleSource.root.path, "modules/middle 雪"])
        let authorMiddle = GitRepository(root: author.root.appendingPathComponent("modules/middle 雪"), executable: git)
        _ = try await authorMiddle.run(["checkout", "--detach", middleTarget])
        _ = try await commit(author, "pin nested submodule target")
        let client = GitRepository(root: directory.appendingPathComponent("client"), executable: git)
        _ = try await parent.run(["clone", "--template=", "--", author.root.path, client.root.path])
        _ = try await client.run(["config", "core.hooksPath", "/dev/null"])
        let middle = GitRepository(root: client.root.appendingPathComponent("modules/middle 雪"), executable: git)
        let leaf = GitRepository(root: middle.root.appendingPathComponent("nested leaf"), executable: git)
        fixtureReady = true
        return Fixture(directory: directory, git: git, client: client, middle: middle, leaf: leaf, middleBase: middleBase, middleTarget: middleTarget, leafTarget: leafTarget)
    }
    func testInitDoesNotCheckoutAndUpdateRecursesToPinnedNestedTargets() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let head = try await hash(f.client), index = try Data(contentsOf: f.client.root.appendingPathComponent(".git/index"))
        _ = try await f.client.synchronizeSubmodules(.initialize, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.middle.root.appendingPathComponent(".git").path))
        let url = try await f.client.run(["config", "--get", "submodule.mid-雪.url"]).text
        XCTAssertTrue(url.contains("middle source"))
        _ = try await f.client.synchronizeSubmodules(.update)
        let middle = try await hash(f.middle), leaf = try await hash(f.leaf), finalHead = try await hash(f.client), branch = try await f.client.branch()
        XCTAssertEqual(middle, f.middleTarget); XCTAssertEqual(leaf, f.leafTarget)
        XCTAssertEqual(finalHead, head); XCTAssertEqual(branch, "main")
        XCTAssertEqual(try Data(contentsOf: f.client.root.appendingPathComponent(".git/index")), index)
    }
    func testRecursiveSyncChangesTopAndNestedRegisteredURLsWithoutMovingHeads() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.client.synchronizeSubmodules(.update)
        let topURL = f.directory.appendingPathComponent("new middle url.git").path, nestedURL = f.directory.appendingPathComponent("new leaf url.git").path
        _ = try await f.client.run(["config", "--file", ".gitmodules", "submodule.mid-雪.url", topURL])
        _ = try await f.middle.run(["config", "--file", ".gitmodules", "submodule.leaf-雪.url", nestedURL])
        let head = try await hash(f.client), middle = try await hash(f.middle), leaf = try await hash(f.leaf), index = try Data(contentsOf: f.client.root.appendingPathComponent(".git/index"))
        let result = try await f.client.synchronizeSubmodules(.sync, force: true)
        XCTAssertEqual(result.exitCode, 0)
        for (repo, key, expected) in [(f.client, "submodule.mid-雪.url", topURL), (f.middle, "remote.origin.url", topURL), (f.middle, "submodule.leaf-雪.url", nestedURL), (f.leaf, "remote.origin.url", nestedURL)] {
            let actual = try await repo.run(["config", "--get", key]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(actual, expected)
        }
        let finalHead = try await hash(f.client), finalMiddle = try await hash(f.middle), finalLeaf = try await hash(f.leaf)
        XCTAssertEqual(finalHead, head); XCTAssertEqual(finalMiddle, middle); XCTAssertEqual(finalLeaf, leaf)
        XCTAssertEqual(try Data(contentsOf: f.client.root.appendingPathComponent(".git/index")), index)
    }
    func testDirtyCheckoutFailureForceAndConfiguredNoneUpdateMode() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.client.synchronizeSubmodules(.update)
        _ = try await f.middle.run(["checkout", "--detach", f.middleBase])
        try Data("uncommitted work\n".utf8).write(to: f.middle.root.appendingPathComponent("middle.txt"))
        do { _ = try await f.client.synchronizeSubmodules(.update); XCTFail("Dirty child must reject checkout") }
        catch is GitFailure {}
        let refused = try await hash(f.middle); XCTAssertEqual(refused, f.middleBase)
        _ = try await f.client.synchronizeSubmodules(.update, force: true)
        let forced = try await hash(f.middle); XCTAssertEqual(forced, f.middleTarget)
        XCTAssertEqual(try String(contentsOf: f.middle.root.appendingPathComponent("middle.txt")), "middle target\n")
        _ = try await f.middle.run(["checkout", "--detach", f.middleBase])
        _ = try await f.client.run(["config", "submodule.mid-雪.update", "none"])
        _ = try await f.client.synchronizeSubmodules(.update, force: true)
        let skipped = try await hash(f.middle); XCTAssertEqual(skipped, f.middleBase)
    }
    func testBareUnsafeMetadataAndPreCancellationRefuseWrites() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bare = GitRepository(root: f.directory.appendingPathComponent("bare.git"), executable: f.git)
        _ = try await f.client.run(["init", "--bare", "--template=", bare.root.path])
        do { _ = try await bare.synchronizeSubmodules(.initialize); XCTFail("Bare roots cannot update submodules") }
        catch is SubmoduleSyncFailure {}
        let config = try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")), token = OperationCancellation(); token.cancel()
        do { _ = try await f.client.synchronizeSubmodules(.initialize, cancellation: token); XCTFail("Cancelled preflight must not write config") }
        catch is OperationCancellationFailure {}
        let modules = f.client.root.appendingPathComponent(".gitmodules"), external = f.directory.appendingPathComponent("external-modules")
        try FileManager.default.copyItem(at: modules, to: external); try FileManager.default.removeItem(at: modules); try FileManager.default.createSymbolicLink(at: modules, withDestinationURL: external)
        do { _ = try await f.client.synchronizeSubmodules(.initialize); XCTFail("Symlink metadata must not be used") }
        catch is SubmoduleComparisonFailure {}
        XCTAssertEqual(try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")), config)
    }
}
