import XCTest
@testable import TurtleGitCore

private final class TestBookmarks: RepositoryBookmarkProvider {
    var creates = 0
    var starts = 0
    var stops = 0
    var stale = false
    var scopeAvailable = true
    var movedURL: URL?
    var failResolution = false
    func create(for url: URL) throws -> Data { creates += 1; return Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        if failResolution { throw RepositoryAccessFailure.securityScopeUnavailable }
        return ResolvedBookmark(url: movedURL ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: stale)
    }
    func startAccessing(_ url: URL) -> Bool { starts += 1; return scopeAvailable }
    func stopAccessing(_ url: URL) { stops += 1 }
}

final class RepositoryAccessTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, folder.appendingPathComponent("private/repositories.json"))
    }
    func testSavedPermissionSurvivesRelaunchAndForgetDoesNotDeleteRepository() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let provider = TestBookmarks(), repository = folder.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let store = try RepositoryAccessStore(storageURL: storage, provider: provider)
        let saved = try store.remember(repository)
        let relaunched = try RepositoryAccessStore(storageURL: storage, provider: provider)
        XCTAssertEqual(relaunched.repositories.map(\.id), [saved.id])
        XCTAssertEqual(relaunched.repositories[0].lastKnownPath, repository.resolvingSymlinksInPath().path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: storage.path)[.posixPermissions] as? NSNumber, 0o600)
        try relaunched.forget(saved.id)
        XCTAssertTrue(try RepositoryAccessStore(storageURL: storage, provider: provider).repositories.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.path))
    }
    func testScopeHeldThroughSessionAndBalancedOnRelease() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let provider = TestBookmarks(), store = try RepositoryAccessStore(storageURL: storage, provider: provider)
        let saved = try store.remember(folder)
        var lease: RepositoryAccessLease? = try store.acquire(saved.id, requireSecurityScope: true)
        XCTAssertEqual(provider.starts, 1); XCTAssertEqual(provider.stops, 0)
        XCTAssertTrue(lease!.contains(folder.appendingPathComponent("file")))
        lease = nil
        XCTAssertEqual(provider.stops, 1)
    }
    func testUnavailableScopeRequiresReselectionWithoutUnbalancedStop() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let provider = TestBookmarks(), store = try RepositoryAccessStore(storageURL: storage, provider: provider)
        let saved = try store.remember(folder); provider.scopeAvailable = false
        XCTAssertThrowsError(try store.acquire(saved.id, requireSecurityScope: true))
        XCTAssertEqual(provider.starts, 1); XCTAssertEqual(provider.stops, 0)
        XCTAssertEqual(store.repositories[0].id, saved.id)
    }
    func testStaleMovedBookmarkRenewsWithoutDuplicatingEntry() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let provider = TestBookmarks(), store = try RepositoryAccessStore(storageURL: storage, provider: provider)
        let saved = try store.remember(folder.appendingPathComponent("old"))
        let moved = folder.appendingPathComponent("new")
        provider.stale = true; provider.movedURL = moved
        let lease = try store.acquire(saved.id)
        XCTAssertEqual(provider.creates, 2)
        XCTAssertEqual(store.repositories.count, 1); XCTAssertEqual(store.repositories[0].id, saved.id)
        XCTAssertEqual(lease.url.path, moved.path)
        XCTAssertEqual(store.repositories[0].lastKnownPath, moved.resolvingSymlinksInPath().path)
    }
    func testPathBoundaryTraversalAndSymlinkCannotWidenGrant() throws {
        let (folder, _) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("repo", isDirectory: true)
        let outside = folder.appendingPathComponent("repo-other", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let lease = RepositoryAccessLease(url: root, provider: TestBookmarks())
        XCTAssertTrue(lease.contains(root.appendingPathComponent("nested/file.txt")))
        XCTAssertFalse(lease.contains(outside))
        XCTAssertFalse(lease.contains(root.appendingPathComponent("../repo-other/file.txt")))
        XCTAssertFalse(lease.contains(root.appendingPathComponent("escape/file.txt")))
        XCTAssertFalse(lease.contains(URL(string: "https://example.invalid" + root.path)!))
    }
    func testFailedResolutionKeepsSavedBookmarkAndNeverStartsAccess() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let provider = TestBookmarks(), store = try RepositoryAccessStore(storageURL: storage, provider: provider)
        let saved = try store.remember(folder); provider.failResolution = true
        XCTAssertThrowsError(try store.acquire(saved.id))
        XCTAssertEqual(provider.starts, 0); XCTAssertEqual(store.repositories, [saved])
    }
    func testCorruptStoreFailsVisiblyRatherThanOverwritingPermissions() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("broken".utf8); try corrupt.write(to: storage)
        XCTAssertThrowsError(try RepositoryAccessStore(storageURL: storage, provider: TestBookmarks()))
        XCTAssertEqual(try Data(contentsOf: storage), corrupt)
    }
    func testRecentRepositoriesDeduplicateAndKeepMostRecentlyOpenedFirst() throws {
        let (folder, storage) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try RepositoryAccessStore(storageURL: storage, provider: TestBookmarks())
        let a = try store.remember(folder.appendingPathComponent("a"))
        let b = try store.remember(folder.appendingPathComponent("b"))
        let repeated = try store.remember(folder.appendingPathComponent("a"))
        XCTAssertEqual(repeated.id, a.id)
        XCTAssertEqual(store.repositories.map(\.id), [a.id, b.id])
    }
    func testAppStoreRuntimeCannotSilentlyUseSystemGit() throws {
        let (folder, _) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let bundleURL = folder.appendingPathComponent("NoGit.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "org.turtlegit.test.no-runtime", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertThrowsError(try GitRuntime.executable(bundle: bundle, appStore: true))
        XCTAssertEqual(try GitRuntime.executable(bundle: bundle, appStore: false).path, "/usr/bin/git")
    }
}
