// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class FinderActionHandoffTests: XCTestCase {
    private func fixture(_ run: (FinderActionHandoff) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-action-handoff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        try run(FinderActionHandoff(root: base.appendingPathComponent("actions")))
    }
    func testColdArgumentsAndURLCarryOneBoundedReceiptForExactSelection() throws {
        try fixture { store in
            let paths = ["/repo 雪/space &?\n[*].txt", "/repo 雪/e\u{301}.txt"].map { URL(fileURLWithPath: $0) }
            let request = FinderRequest(action: .commit, paths: paths)
            let delivery = try store.publish(request)
            XCTAssertEqual(FinderActionDelivery(url: delivery.url), delivery)
            XCTAssertEqual(FinderActionDelivery.parse(arguments: delivery.arguments), delivery)
            XCTAssertEqual(delivery.arguments.count, 2)
            XCTAssertLessThan(delivery.arguments.joined().utf8.count, 256)
            XCTAssertFalse(delivery.arguments.joined().contains("/repo"))
            let actual = try store.consume(delivery)
            XCTAssertEqual(actual.action, .commit)
            XCTAssertEqual(actual.paths.map { Data($0.path.utf8) }, paths.map { Data($0.path.utf8) })
            XCTAssertThrowsError(try store.consume(delivery))
        }
    }
    func testAllValidCommandsRetainTheirOriginalPayload() throws {
        try fixture { store in
            let root = URL(fileURLWithPath: "/repo 雪", isDirectory: true)
            let requests = [
                FinderRequest(action: .registerRepository, paths: [root]),
                FinderRequest(action: .diff, paths: [root], alternateTool: true),
                FinderRequest(action: .requestPull, paths: [root], requestPullEnd: "feature/雪", requestPullURL: "ssh://host/space &?#.git"),
                FinderRequest(action: .reviewPatch, paths: [root], clipboardPatch: FinderPatchHandoff.unavailable),
                FinderRequest(action: .pasteCopy, paths: [root], sources: [root.appendingPathComponent("source\n.txt")])
            ]
            for request in requests {
                let receipt = try store.publish(request), actual = try store.consume(receipt)
                XCTAssertEqual(actual.url?.absoluteString, request.url?.absoluteString)
            }
        }
    }
    func testLargePayloadStaysOffArgvAndSeparateRequestsStayDistinct() throws {
        try fixture { store in
            let request = FinderRequest(action: .requestPull, paths: [URL(fileURLWithPath: "/repo")], requestPullURL: "ssh://host/" + String(repeating: "x", count: 300_000))
            let first = try store.publish(request), second = try store.publish(request)
            XCTAssertNotEqual(first.receipt, second.receipt)
            XCTAssertLessThan(first.arguments.joined().utf8.count, 256)
            XCTAssertEqual(try store.consume(first).requestPullURL, request.requestPullURL)
            XCTAssertEqual(try store.consume(second).requestPullURL, request.requestPullURL)
        }
    }
    func testEnvelopeRejectsAmbiguityTraversalAndNonActionURLs() throws {
        let delivery = try XCTUnwrap(FinderActionDelivery(receipt: UUID().uuidString.lowercased(), action: .commit))
        for extra in ["&receipt=" + delivery.receipt, "&command=log", "&unknown=1", "#fragment", "&path=/repo"] {
            XCTAssertNil(FinderActionDelivery(url: try XCTUnwrap(URL(string: delivery.url.absoluteString + extra))))
        }
        XCTAssertNil(FinderActionDelivery(receipt: "../outside", action: .commit))
        XCTAssertNil(FinderActionDelivery(receipt: delivery.receipt.uppercased(), action: .commit))
        XCTAssertNil(FinderActionDelivery(url: try XCTUnwrap(FinderRequest(action: .commit, paths: [URL(fileURLWithPath: "/repo")]).url)))
        XCTAssertNil(FinderActionDelivery.parse(arguments: [FinderActionDelivery.argumentFlag]))
        XCTAssertNil(FinderActionDelivery.parse(arguments: delivery.arguments + ["extra"]))
        var components = try XCTUnwrap(URLComponents(url: delivery.url, resolvingAgainstBaseURL: false))
        for path in ["/", "/file"] { components.path = path; XCTAssertNil(FinderActionDelivery(url: try XCTUnwrap(components.url))) }
    }
    func testOnlyOneRacingReceiverConsumesThePrivatePayload() throws {
        try fixture { store in
            let delivery = try store.publish(FinderRequest(action: .commit, paths: [URL(fileURLWithPath: "/repo")]))
            let lock = NSLock()
            var accepted: [RepositoryAction] = []
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                if let request = try? store.consume(delivery) {
                    lock.lock(); accepted.append(request.action); lock.unlock()
                }
            }
            XCTAssertEqual(accepted, [.commit])
        }
    }
    func testWrongActionMissingDiscardedAndMalformedPayloadsCannotDispatch() throws {
        try fixture { store in
            let original = try store.publish(FinderRequest(action: .commit, paths: [URL(fileURLWithPath: "/repo")]))
            let mismatch = try XCTUnwrap(FinderActionDelivery(receipt: original.receipt, action: .remove))
            XCTAssertThrowsError(try store.consume(mismatch))
            XCTAssertThrowsError(try store.consume(original))
            let malformed = try FinderPatchHandoff(root: store.root).publish(Data("file:///outside".utf8))
            XCTAssertThrowsError(try store.consume(XCTUnwrap(FinderActionDelivery(receipt: malformed, action: .commit))))
            let discarded = try store.publish(FinderRequest(action: .log, paths: [URL(fileURLWithPath: "/repo")]))
            store.discard(discarded)
            XCTAssertThrowsError(try store.consume(discarded))
        }
    }
    func testPayloadLimitIsAppliedBeforeReadingAndOutsideTargetsAreUntouched() throws {
        try fixture { store in
            let files = FinderPatchHandoff(root: store.root)
            let receipt = try files.publish(Data(repeating: 65, count: FinderActionHandoff.maximumBytes + 1))
            XCTAssertThrowsError(try store.consume(XCTUnwrap(FinderActionDelivery(receipt: receipt, action: .commit))))
            let outside = store.root.deletingLastPathComponent().appendingPathComponent("outside")
            try Data("unchanged".utf8).write(to: outside)
            let link = UUID().uuidString.lowercased()
            try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent(link + ".patch"), withDestinationURL: outside)
            XCTAssertThrowsError(try store.consume(XCTUnwrap(FinderActionDelivery(receipt: link, action: .commit))))
            XCTAssertEqual(try Data(contentsOf: outside), Data("unchanged".utf8))
        }
    }
}
