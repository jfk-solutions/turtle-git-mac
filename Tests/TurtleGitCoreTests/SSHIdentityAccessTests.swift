// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

private final class IdentityBookmarks: RepositoryBookmarkProvider {
    var starts = 0, stops = 0, creates = 0, resolves = 0
    var available = true, stale = false, fails = false
    var moved: URL?
    func create(for url: URL) throws -> Data { creates += 1; return Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        resolves += 1
        if fails { throw SSHIdentityAccessFailure.permission }
        return ResolvedBookmark(url: moved ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: stale)
    }
    func startAccessing(_ url: URL) -> Bool { starts += 1; return available }
    func stopAccessing(_ url: URL) { stops += 1 }
}
final class SSHIdentityAccessTests: XCTestCase {
    func testRelaunchReadOnlyLeaseStaleMovedRenewalAndForget() throws {
        let root = try SSHAgentSessionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("key ' ☃"), moved = root.appendingPathComponent("moved-key"), storage = root.appendingPathComponent("private/grants.json")
        let marker = Data("private fixture bytes never saved".utf8); try marker.write(to: key)
        let provider = IdentityBookmarks(), store = SSHIdentityAccessStore(storageURL: storage, provider: provider)
        try store.remember(key, requireSecurityScope: true)
        XCTAssertEqual(provider.starts, 1); XCTAssertEqual(provider.stops, 1)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: storage.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: storage.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        XCTAssertNil(try Data(contentsOf: storage).range(of: marker))
        let reopened = SSHIdentityAccessStore(storageURL: storage, provider: provider)
        var access: SSHIdentityAccess? = try reopened.acquire(path: key.path, requireSecurityScope: true)
        XCTAssertEqual(access?.file, key); XCTAssertEqual(provider.starts, 2); XCTAssertEqual(provider.stops, 1)
        access = nil; XCTAssertEqual(provider.stops, 2)
        try FileManager.default.moveItem(at: key, to: moved); provider.moved = moved; provider.stale = true
        do { let renewed = try reopened.acquire(path: key.path, requireSecurityScope: true); XCTAssertEqual(renewed.file, moved); XCTAssertEqual(provider.creates, 2) }
        provider.moved = nil; provider.stale = false
        do { let renewed = try reopened.acquire(path: key.path); XCTAssertEqual(renewed.file, moved) }
        try reopened.forget(path: key.path); XCTAssertThrowsError(try reopened.acquire(path: key.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertEqual(provider.starts, provider.stops)
    }
    func testPermissionListingAndReviewedRemovalPreserveFilesAndLiveLeases() throws {
        let root = try SSHAgentSessionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), moved = root.appendingPathComponent("moved"), extra = root.appendingPathComponent("extra")
        for file in [a, b, extra] { try Data("private fixture".utf8).write(to: file) }
        let provider = IdentityBookmarks(), store = SSHIdentityAccessStore(storageURL: root.appendingPathComponent("private/grants.json"), provider: provider)
        try store.remember(a); try store.remember(b)
        let starts = provider.starts, stops = provider.stops
        let reviewed = try store.grants()
        XCTAssertEqual(reviewed.map(\.configuredPath), [a.path, b.path]); XCTAssertEqual(provider.resolves, 0)
        XCTAssertEqual(provider.starts, starts); XCTAssertEqual(provider.stops, stops)
        try FileManager.default.moveItem(at: a, to: moved); provider.moved = moved; provider.stale = true
        var live: SSHIdentityAccess? = try store.acquire(path: a.path, requireSecurityScope: true)
        XCTAssertEqual(live?.file, moved)
        provider.moved = nil; provider.stale = false
        try store.remember(extra)
        let before = try Data(contentsOf: store.storageURL)
        XCTAssertThrowsError(try store.forget(reviewed)) { error in guard case SSHIdentityAccessFailure.changed = error else { return XCTFail("Wrong stale permission failure") } }
        XCTAssertEqual(try Data(contentsOf: store.storageURL), before)
        let current = try store.grants(); try store.forget(current.filter { $0.id != GitReferenceName(extra.path) })
        XCTAssertEqual(try store.grants().map(\.configuredPath), [extra.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertEqual(provider.starts, provider.stops + 1); live = nil; XCTAssertEqual(provider.starts, provider.stops)
        XCTAssertThrowsError(try store.acquire(path: a.path))
        try FileManager.default.removeItem(at: extra); provider.fails = true
        let missing = try store.grants(); XCTAssertEqual(missing.count, 1)
        try store.forget(missing); XCTAssertTrue(try store.grants().isEmpty)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.storageURL.path)[.posixPermissions] as? Int, 0o600)
    }
    func testDeniedMissingMalformedSymlinkAndPuTTYNeverAuthorize() throws {
        let root = try SSHAgentSessionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("key"), storage = root.appendingPathComponent("private/grants.json")
        try Data("fixture".utf8).write(to: key)
        let provider = IdentityBookmarks(), store = SSHIdentityAccessStore(storageURL: storage, provider: provider)
        provider.available = false; XCTAssertThrowsError(try store.remember(key, requireSecurityScope: true)); XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path)); XCTAssertEqual(provider.stops, 0)
        provider.available = true; try store.remember(key)
        let saved = try Data(contentsOf: storage)
        provider.fails = true; XCTAssertThrowsError(try store.acquire(path: key.path)); provider.fails = false
        provider.available = false; XCTAssertThrowsError(try store.acquire(path: key.path, requireSecurityScope: true)); provider.available = true
        XCTAssertThrowsError(try store.acquire(path: root.appendingPathComponent("other").path)); XCTAssertThrowsError(try store.acquire(path: "relative"))
        XCTAssertThrowsError(try store.remember(root)); XCTAssertThrowsError(try store.remember(root.appendingPathComponent("missing")))
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key); XCTAssertThrowsError(try store.remember(link))
        let putty = root.appendingPathComponent("identity.any-extension"); try Data("PuTTY-User-Key-File-3: ssh-ed25519\n".utf8).write(to: putty)
        XCTAssertThrowsError(try store.remember(putty)) { error in guard case SSHIdentityAccessFailure.putty = error else { return XCTFail("Wrong PPK failure") } }
        XCTAssertEqual(try Data(contentsOf: storage), saved)
        try Data("broken JSON".utf8).write(to: storage); XCTAssertThrowsError(try store.remember(key)); XCTAssertEqual(try Data(contentsOf: storage), Data("broken JSON".utf8))
    }
    func testByteDistinctGrantPathsAreNotMerged() throws {
        let root = try SSHAgentSessionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = IdentityBookmarks(), storage = root.appendingPathComponent("private/grants.json")
        let store = SSHIdentityAccessStore(storageURL: storage, provider: provider)
        // File-URL convenience construction may merge canonically equal Swift
        // strings. Explicit escaped URLs supply genuinely different path bytes.
        let a = URL(string: root.absoluteString + "/Caf%C3%A9")!, b = URL(string: root.absoluteString + "/Cafe%CC%81")!
        XCTAssertNotEqual(Data(a.path.utf8), Data(b.path.utf8))
        // macOS may store the same inode under normalized names; the configured
        // Git strings must nevertheless remain byte-distinct lookup identities.
        try Data("fixture".utf8).write(to: a); try Data("fixture".utf8).write(to: b); try store.remember(a); try store.remember(b)
        let grants = try store.grants(); XCTAssertEqual(Set(grants.map(\.id)).count, 2); XCTAssertNotEqual(grants[0], grants[1])
        try store.forget([grants.first { $0.id == GitReferenceName(a.path) }!]); XCTAssertThrowsError(try store.acquire(path: a.path))
        let surviving = try store.acquire(path: b.path); XCTAssertTrue(surviving.permission.hasSecurityScope)
    }
}
