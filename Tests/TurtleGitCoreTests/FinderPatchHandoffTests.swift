import XCTest
import Darwin
@testable import TurtleGitCore

final class FinderPatchHandoffTests: XCTestCase {
    func fixture(_ body: (URL, FinderPatchHandoff) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-PatchHandoff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base, FinderPatchHandoff(root: base.appendingPathComponent("handoff")))
    }
    func testExactBytesPermissionsReopenAndOneUse() throws {
        try fixture { _, store in
            let bytes = Data([0, 255, 13, 10]) + Data("diff --git a/雪 b/雪\n".utf8)
            let receipt = try store.publish(bytes)
            XCTAssertTrue(FinderPatchHandoff.validReceipt(receipt))
            let path = store.root.appendingPathComponent(receipt + ".patch")
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try FinderPatchHandoff(root: store.root).consume(receipt), bytes)
            XCTAssertThrowsError(try store.consume(receipt)); XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
            XCTAssertThrowsError(try store.publish(Data()))
        }
    }
    func testConcurrentClaimsReturnExactlyOneSnapshot() throws {
        try fixture { _, store in
            let receipt = try store.publish(Data("snapshot".utf8)), lock = NSLock()
            var results: [Data] = []
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                if let bytes = try? store.consume(receipt) { lock.lock(); results.append(bytes); lock.unlock() }
            }
            XCTAssertEqual(results, [Data("snapshot".utf8)])
        }
    }
    func testTypedReceiptRoundTripRejectsOtherCommandsDuplicatesPathsAndTraversal() throws {
        let receipt = "01234567-89ab-4cde-8fab-0123456789ab", path = URL(fileURLWithPath: "/repo 雪\n/selected.txt")
        for value in [receipt, FinderPatchHandoff.unavailable] {
            let request = FinderRequest(action: .reviewPatch, paths: [path], alternateTool: true, clipboardPatch: value)
            let url = try XCTUnwrap(request.url), parsed = try XCTUnwrap(FinderRequest(url: url))
            XCTAssertEqual(parsed.clipboardPatch, value); XCTAssertEqual(parsed.paths.map(\.path), [path.path]); XCTAssertEqual(parsed.alternateTool, true)
            XCTAssertNil(FinderRequest(url: try XCTUnwrap(URL(string: url.absoluteString + "&clipboardpatch=" + receipt))))
            XCTAssertNil(FinderRequest(url: try XCTUnwrap(URL(string: url.absoluteString + "&path=/other"))))
        }
        XCTAssertNil(FinderRequest(action: .commit, paths: [path], clipboardPatch: receipt).url)
        XCTAssertNil(FinderRequest(action: .reviewPatch, paths: [], clipboardPatch: receipt).url)
        for bad in ["", "../outside", receipt.uppercased(), receipt + "/file", "bad\0name"] {
            XCTAssertNil(FinderRequest(action: .reviewPatch, paths: [path], clipboardPatch: bad).url)
        }
        XCTAssertNil(try XCTUnwrap(FinderRequest(url: XCTUnwrap(FinderRequest(action: .reviewPatch, paths: [path]).url))).clipboardPatch)
    }
    func testExpiredSymlinkFIFOAndOversizedRecordsNeverReadOutside() throws {
        try fixture { base, store in
            let bytes = Data("outside".utf8), external = base.appendingPathComponent("outside")
            try bytes.write(to: external)
            let expired = try store.publish(Data("old".utf8)), expiredPath = store.root.appendingPathComponent(expired + ".patch")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -700)], ofItemAtPath: expiredPath.path)
            XCTAssertThrowsError(try store.consume(expired))
            let link = UUID().uuidString.lowercased(), linkPath = store.root.appendingPathComponent(link + ".patch")
            try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: external)
            XCTAssertThrowsError(try store.consume(link)); XCTAssertEqual(try Data(contentsOf: external), bytes)
            let fifo = UUID().uuidString.lowercased(), fifoPath = store.root.appendingPathComponent(fifo + ".patch")
            XCTAssertEqual(mkfifo(fifoPath.path, 0o600), 0); XCTAssertThrowsError(try store.consume(fifo))
            let large = try store.publish(Data("size".utf8)), largePath = store.root.appendingPathComponent(large + ".patch")
            let handle = try FileHandle(forWritingTo: largePath); try handle.truncate(atOffset: UInt64(FinderPatchHandoff.maximumBytes) + 1); try handle.close()
            XCTAssertThrowsError(try store.consume(large))
            XCTAssertThrowsError(try store.consume("../outside")); store.discard("../outside")
            XCTAssertEqual(try Data(contentsOf: external), bytes)
            let alias = base.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: store.root)
            XCTAssertThrowsError(try FinderPatchHandoff(root: alias).publish(bytes))
        }
    }
    func testPruningOwnNamespaceBoundsAndDiscard() throws {
        try fixture { _, store in
            let first = try store.publish(Data("old".utf8))
            let foreign = store.root.appendingPathComponent("preferences.json"); try Data("retained".utf8).write(to: foreign)
            for index in 0..<35 {
                let path = store.root.appendingPathComponent(UUID().uuidString.lowercased() + ".patch")
                try Data([UInt8(index)]).write(to: path)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: path.path)
            }
            let stale = store.root.appendingPathComponent(UUID().uuidString.lowercased() + ".tmp")
            try Data("partial".utf8).write(to: stale)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -700)], ofItemAtPath: stale.path)
            let receipt = try store.publish(Data("new".utf8))
            XCTAssertEqual(try Data(contentsOf: foreign), Data("retained".utf8)); XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
            let own = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasSuffix(".patch") }
            XCTAssertLessThanOrEqual(own.count, 32)
            XCTAssertEqual(try store.consume(receipt), Data("new".utf8)); store.discard(first)
            XCTAssertThrowsError(try store.consume(first))
        }
    }
}
