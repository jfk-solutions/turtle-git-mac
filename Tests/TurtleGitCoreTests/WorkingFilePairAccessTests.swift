import XCTest
@testable import TurtleGitCore

final class WorkingFilePairAccessTests: XCTestCase {
    final class Provider: RepositoryBookmarkProvider {
        var starts: [URL] = [], stops: [URL] = []
        var allowed = true
        func create(for url: URL) throws -> Data { Data() }
        func resolve(_ data: Data) throws -> ResolvedBookmark { throw RevisionComparisonFailure.selection }
        func startAccessing(_ url: URL) -> Bool { starts.append(url); return allowed }
        func stopAccessing(_ url: URL) { stops.append(url) }
    }
    func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = root.appendingPathComponent("one 雪", isDirectory: true), second = root.appendingPathComponent("two", isDirectory: true)
        for dir in [first, second] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let a = first.appendingPathComponent("literal &?\n.txt"), b = second.appendingPathComponent("other.bin")
        try Data([0xef, 0xbb, 0xbf, 97, 13, 10]).write(to: a)
        try Data([0, 255, 42]).write(to: b)
        return (root, a, b)
    }
    func testFinderRequestOrderLiveBytesAndGrantLifetime() throws {
        let (root, a, b) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = Provider()
        let request = try XCTUnwrap(FinderRequest(url: try XCTUnwrap(FinderRequest(action: .diff, paths: [a, b]).url)))
        var prepared = try WorkingFilePairAccess.prepare(paths: request.paths, requireSecurityScope: true) {
            RepositoryAccessLease(url: $0.deletingLastPathComponent(), provider: provider)
        }
        XCTAssertEqual(prepared?.comparison.base, a); XCTAssertEqual(prepared?.comparison.destination, b)
        XCTAssertEqual(provider.starts.count, 2); XCTAssertTrue(provider.stops.isEmpty)
        XCTAssertEqual(try prepared?.comparison.read().base.bytes, Data([0xef, 0xbb, 0xbf, 97, 13, 10]))
        XCTAssertEqual(try prepared?.comparison.read().destination.bytes, Data([0, 255, 42]))
        try Data("new working bytes".utf8).write(to: a)
        XCTAssertEqual(try prepared?.comparison.read().base.bytes, Data("new working bytes".utf8))
        prepared = nil
        XCTAssertEqual(Set(provider.stops), Set(provider.starts))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
    }
    func testCancellationAndWrongOrUnavailableGrant() throws {
        let (root, a, b) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = Provider(); var acquired = 0
        let cancelled = try WorkingFilePairAccess.prepare(paths: [a, b], requireSecurityScope: true) { file in
            acquired += 1
            return acquired == 2 ? nil : RepositoryAccessLease(url: file, provider: provider)
        }
        XCTAssertNil(cancelled); XCTAssertEqual(provider.starts, provider.stops)
        XCTAssertThrowsError(try WorkingFilePairAccess.prepare(paths: [a, b], requireSecurityScope: true) { _ in
            RepositoryAccessLease(url: b, provider: provider)
        })
        provider.allowed = false
        XCTAssertThrowsError(try WorkingFilePairAccess.prepare(paths: [a, b], requireSecurityScope: true) {
            RepositoryAccessLease(url: $0, provider: provider)
        })
        XCTAssertNotNil(try WorkingFilePairAccess.prepare(paths: [a, b], requireSecurityScope: false) {
            RepositoryAccessLease(url: $0, provider: provider)
        })
        XCTAssertEqual(try Data(contentsOf: b), Data([0, 255, 42]))
    }
    func testRepositoryPairReadsWorkingBytesWithoutChangingIndexOrHead() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent(path), b = root.appendingPathComponent("second 雪.txt")
        try Data("staged version".utf8).write(to: a); try await repo.stage([path])
        let working = Data([0xff, 0xfe]) + "working version\r\n".data(using: .utf16LittleEndian)!
        try working.write(to: a); try Data("other working file".utf8).write(to: b)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        let provider = Provider()
        let prepared = try XCTUnwrap(WorkingFilePairAccess.prepare(paths: [a, b], requireSecurityScope: true) { _ in
            RepositoryAccessLease(url: root, provider: provider)
        })
        let document = try prepared.comparison.read()
        XCTAssertEqual(document.base.bytes, working)
        XCTAssertEqual(document.destination.bytes, Data("other working file".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let currentHead = try await repo.run(["rev-parse", "HEAD"]).text
        XCTAssertEqual(currentHead, head)
        XCTAssertEqual(try Data(contentsOf: a), working)
    }
    func testInvalidPairsAndDirectoriesAreRejected() throws {
        let (root, a, b) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = Provider()
        for paths in [[], [a], [a, a], [a, b, root], [root, b]] {
            XCTAssertThrowsError(try WorkingFilePairAccess.prepare(paths: paths, requireSecurityScope: true) {
                RepositoryAccessLease(url: $0, provider: provider)
            })
        }
        try FileManager.default.removeItem(at: b)
        XCTAssertThrowsError(try WorkingFilePairAccess.prepare(paths: [a, b], requireSecurityScope: true) {
            RepositoryAccessLease(url: $0, provider: provider)
        })
    }
}
