import XCTest
@testable import TurtleGitCore

final class CleanSubmoduleTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository, [GitRepository], String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitCleanModules-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        let executable = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/git")
        func make(_ name: String) async throws -> GitRepository {
            let location = base.appendingPathComponent(name); try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
            let repo = GitRepository(root: location, executable: executable)
            _ = try await repo.run(["init", "-b", "main"])
            _ = try await repo.run(["config", "user.name", "Clean Module QA"])
            _ = try await repo.run(["config", "user.email", "modules@example.invalid"])
            _ = try await repo.run(["config", "commit.gpgsign", "false"])
            try Data("base\n".utf8).write(to: location.appendingPathComponent("tracked"))
            try await repo.stage(["tracked"]); _ = try await repo.commit(message: "base")
            return repo
        }
        do {
            let grandSource = try await make("grand-source"), childSource = try await make("child-source"), parent = try await make("parent")
            _ = try await childSource.run(["-c", "protocol.file.allow=always", "submodule", "add", "--name", "nested", "--", grandSource.root.path, "nested"])
            _ = try await childSource.commit(message: "attach nested")
            let childPath = "group/module 雪\ncheckout"
            _ = try await parent.run(["-c", "protocol.file.allow=always", "submodule", "add", "--name", "child", "--", childSource.root.path, childPath])
            for name in ["sibling", "missing"] {
                _ = try await parent.run(["-c", "protocol.file.allow=always", "submodule", "add", "--name", name, "--", grandSource.root.path, name])
            }
            _ = try await parent.commit(message: "attach children")
            _ = try await parent.run(["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"])
            _ = try await parent.run(["submodule", "deinit", "-f", "--", "missing"])
            let child = GitRepository(root: parent.root.appendingPathComponent(childPath), executable: executable)
            let grand = GitRepository(root: child.root.appendingPathComponent("nested"), executable: executable)
            let sibling = GitRepository(root: parent.root.appendingPathComponent("sibling"), executable: executable)
            for (repo, junk) in zip([parent, child, grand, sibling], ["parent-junk", "child-junk", "grand-junk", "sibling-junk"]) {
                try Data(junk.utf8).write(to: repo.root.appendingPathComponent(junk))
                try Data("staged\n".utf8).write(to: repo.root.appendingPathComponent("tracked")); try await repo.stage(["tracked"])
                try Data("working\n".utf8).write(to: repo.root.appendingPathComponent("tracked"))
            }
            return (base, parent, [parent, child, grand, sibling], childPath)
        } catch { try? FileManager.default.removeItem(at: base); throw error }
    }
    private func administration(_ repo: GitRepository, _ name: String) async throws -> URL {
        var bytes = try await repo.run(["rev-parse", "--git-path", name]).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.root.appendingPathComponent(path)
    }
    func testRecursiveDiscoveryScopedFoldersAndAdministrativeAccessLocations() async throws {
        let (base, parent, repositories, childPath) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let ordinary = try await parent.cleanBatchPreview(); XCTAssertEqual(ordinary.repositories.count, 1)
        let recursive = try await parent.cleanBatchPreview(includeSubmodules: true)
        XCTAssertEqual(recursive.repositories.map { $0.repository.path }, repositories.map { $0.root.path })
        XCTAssertEqual(recursive.repositories.map { $0.preview.candidates }, [["parent-junk"], ["child-junk"], ["grand-junk"], ["sibling-junk"]])
        for entry in recursive.repositories {
            XCTAssertTrue(entry.requiredAccess.contains { $0.path == entry.repository.resolvingSymlinksInPath().path })
            XCTAssertTrue(entry.requiredAccess.allSatisfy { RepositoryAccessLease.pathIsContained($0, by: parent.root) })
        }
        let scoped = try await parent.cleanBatchPreview(paths: ["group/"], includeSubmodules: true)
        XCTAssertEqual(scoped.repositories.map { $0.repository.path }, Array(repositories.prefix(3)).map { $0.root.path })
        XCTAssertTrue(scoped.repositories[0].preview.candidates.isEmpty)
        let exact = try await parent.cleanBatchPreview(paths: [childPath], includeSubmodules: true)
        XCTAssertEqual(exact.repositories.count, 3)
        let none = try await parent.cleanBatchPreview(paths: ["tracked"], includeSubmodules: true); XCTAssertEqual(none.repositories.count, 1)
    }
    func testScopedRecursiveExecutionPreservesParentSiblingAndAllIndexes() async throws {
        let (base, parent, repositories, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        var indexes: [Data] = [], heads: [Data] = [], configs: [Data] = []
        for repo in repositories {
            let index = try await administration(repo, "index"), config = try await administration(repo, "config")
            indexes.append(try Data(contentsOf: index)); configs.append(try Data(contentsOf: config))
            heads.append(try await repo.run(["rev-parse", "HEAD"]).stdout)
        }
        let plan = try await parent.cleanBatchPreview(paths: ["group"], includeSubmodules: true)
        let result = try await parent.executeCleanBatch(plan, permanently: true)
        XCTAssertEqual(result.map { $0.result.removedPaths }, [[], ["child-junk"], ["grand-junk"]])
        XCTAssertEqual(try Data(contentsOf: parent.root.appendingPathComponent("parent-junk")), Data("parent-junk".utf8))
        XCTAssertEqual(try Data(contentsOf: repositories[3].root.appendingPathComponent("sibling-junk")), Data("sibling-junk".utf8))
        for (i, repo) in repositories.enumerated() {
            let index = try await administration(repo, "index"), config = try await administration(repo, "config")
            XCTAssertEqual(try Data(contentsOf: index), indexes[i]); XCTAssertEqual(try Data(contentsOf: config), configs[i])
            let head = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(head, heads[i])
            XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("tracked")), Data("working\n".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: index.path + ".lock"))
        }
    }
    func testFormerSubmoduleCoveredByUnmanagedParentRemovalIsNotExecutedTwice() async throws {
        let (base, parent, repositories, childPath) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        _ = try await parent.run(["rm", "--cached", "--", childPath])
        let index = try await administration(parent, "index"), bytes = try Data(contentsOf: index)
        let plan = try await parent.cleanBatchPreview(options: CleanOptions(unmanagedRepositories: true), includeSubmodules: true)
        XCTAssertTrue(plan.repositories[0].preview.candidates.contains("group/"))
        XCTAssertEqual(plan.repositories.map { $0.repository.path }, [parent.root.path, repositories[3].root.path])
        let result = try await parent.executeCleanBatch(plan, permanently: true)
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repositories[1].root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repositories[3].root.appendingPathComponent("sibling-junk").path))
        XCTAssertEqual(try Data(contentsOf: index), bytes)
    }
    func testLaterChildLockReportsCompletedParentAndPreservesForeignLock() async throws {
        let (base, parent, repositories, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let plan = try await parent.cleanBatchPreview(includeSubmodules: true)
        let childIndex = try await administration(repositories[1], "index")
        let lock = URL(fileURLWithPath: childIndex.path + ".lock"), bytes = Data("owned child lock\n".utf8)
        try bytes.write(to: lock)
        var recovered: [URL] = []
        defer { for url in recovered { try? FileManager.default.removeItem(at: url) } }
        do { _ = try await parent.executeCleanBatch(plan); XCTFail("Child lock ignored") }
        catch let failure as CleanBatchExecutionFailure {
            XCTAssertEqual(failure.failedRepository.path, repositories[1].root.path)
            XCTAssertEqual(failure.completed.count, 1); XCTAssertEqual(failure.completed.first?.result.removedPaths, ["parent-junk"])
            XCTAssertNil(failure.partial); XCTAssertFalse(failure.cancelled)
            recovered = failure.completed.flatMap { $0.result.trashedFiles }
            XCTAssertEqual(recovered.count, 1)
            for url in recovered {
                XCTAssertEqual(try Data(contentsOf: url), Data("parent-junk".utf8))
                XCTAssertTrue(failure.localizedDescription.contains(url.path))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.root.appendingPathComponent("parent-junk").path))
        XCTAssertEqual(try Data(contentsOf: lock), bytes)
        for (repo, name) in zip(repositories.dropFirst(), ["child-junk", "grand-junk", "sibling-junk"]) {
            XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent(name)), Data(name.utf8))
        }
    }
    func testSymlinkedRegisteredCheckoutIsRefusedWithoutRemovingParentCandidates() async throws {
        let (base, parent, repositories, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let child = repositories[1].root, saved = base.appendingPathComponent("saved-child")
        try FileManager.default.moveItem(at: child, to: saved)
        try FileManager.default.createSymbolicLink(atPath: child.path, withDestinationPath: saved.path)
        do { _ = try await parent.cleanBatchPreview(includeSubmodules: true); XCTFail("Symlinked checkout accepted") } catch SubmoduleComparisonFailure.unsafeCheckout {}
        XCTAssertEqual(try Data(contentsOf: parent.root.appendingPathComponent("parent-junk")), Data("parent-junk".utf8))
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("child-junk")), Data("child-junk".utf8))
    }
    func testBatchPreflightRefusesChangedChildTopologyAndCancelledReadBeforeParentRemoval() async throws {
        let (base, parent, repositories, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let plan = try await parent.cleanBatchPreview(includeSubmodules: true)
        try Data("changed child\n".utf8).write(to: repositories[1].root.appendingPathComponent("child-junk"))
        do { _ = try await parent.executeCleanBatch(plan, permanently: true); XCTFail("Changed child accepted") } catch CleanFailure.changed {}
        XCTAssertEqual(try Data(contentsOf: parent.root.appendingPathComponent("parent-junk")), Data("parent-junk".utf8))
        let fresh = try await parent.cleanBatchPreview(includeSubmodules: true)
        _ = try await parent.run(["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--", "missing"])
        do { _ = try await parent.executeCleanBatch(fresh, permanently: true); XCTFail("Changed initialized topology accepted") } catch CleanFailure.changed {}
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await parent.cleanBatchPreview(includeSubmodules: true, cancellation: cancellation); XCTFail("Canceled recursive read accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: parent.root.appendingPathComponent("parent-junk")), Data("parent-junk".utf8))
    }
}
