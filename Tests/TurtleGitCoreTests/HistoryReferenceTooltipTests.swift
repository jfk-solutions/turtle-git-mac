import XCTest
@testable import TurtleGitCore

final class HistoryReferenceTooltipTests: XCTestCase {
    func testLocalDescriptionPrecedesBothSubjectAndAbsentRightSideFallback() {
        let local = RevisionReference(name: "refs/heads/topic"), remote = RevisionReference(name: "refs/remotes/origin/topic")
        let descriptions: [GitReferenceName: String] = ["refs/heads/topic": "first\nsecond", "refs/remotes/origin/topic": "wrong"]
        XCTAssertEqual(HistoryReferenceTooltip.text(reference: local, descriptions: descriptions, fallback: "subject"), "Description:\nfirst\nsecond")
        XCTAssertEqual(HistoryReferenceTooltip.text(reference: local, descriptions: descriptions, fallback: nil), "Description:\nfirst\nsecond")
        XCTAssertEqual(HistoryReferenceTooltip.text(reference: remote, descriptions: descriptions, fallback: "subject"), "subject")
        XCTAssertNil(HistoryReferenceTooltip.text(reference: remote, descriptions: descriptions, fallback: nil))
        XCTAssertEqual(HistoryReferenceTooltip.text(reference: local, descriptions: ["refs/heads/topic": ""], fallback: nil), "Description:\n")
    }
    func testTruncationUsesSourceWideBufferAndLiteralEllipsis() {
        XCTAssertEqual((HistoryReferenceTooltip.text(reference: nil, descriptions: [:], fallback: String(repeating: "x", count: 8191))! as NSString).length, 8191)
        XCTAssertEqual(HistoryReferenceTooltip.text(reference: nil, descriptions: [:], fallback: String(repeating: "x", count: 8192)), String(repeating: "x", count: 8188) + "...")
        let wide = String(repeating: "🐢", count: 4096)
        XCTAssertEqual(HistoryReferenceTooltip.text(reference: nil, descriptions: [:], fallback: wide), String(repeating: "🐢", count: 4094) + "...")
        XCTAssertNil(HistoryReferenceTooltip.text(reference: nil, descriptions: [:], fallback: ""))
    }
    func testDescriptionRecordsPreserveFirstDuplicateCaseUnicodeAndMultiline() {
        let nfc = "caf\u{e9}", nfd = "cafe\u{301}"
        let bytes = Data(("branch.topic.description\nfirst\nline\0branch.topic.description\nsecond\0branch.Topic.description\nother\0branch." + nfc + ".description\nNFC\0branch." + nfd + ".description\nNFD\0branch.empty.description\n\0remote.topic.description\nignored\0malformed\0").utf8)
        let values = HistoryReferenceTooltip.descriptions(from: bytes)
        XCTAssertEqual(values["refs/heads/topic"], "first\nline"); XCTAssertEqual(values["refs/heads/Topic"], "other")
        XCTAssertEqual(values[GitReferenceName("refs/heads/" + nfc)], "NFC"); XCTAssertEqual(values[GitReferenceName("refs/heads/" + nfd)], "NFD")
        XCTAssertEqual(values["refs/heads/empty"], ""); XCTAssertEqual(values.count, 5)
        XCTAssertFalse(HistoryReferenceTooltip.equalDescriptions(["refs/heads/topic": nfc], ["refs/heads/topic": nfd]))
        XCTAssertTrue(HistoryReferenceTooltip.equalDescriptions(values, values))
    }
    func testLocalGitDescriptionReadAndCancellationLeaveRepositoryUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitRefDescription-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "--initial-branch=main"])
        _ = try await repo.run(["config", "--local", "--add", "branch.topic.description", "first\nline"])
        _ = try await repo.run(["config", "--local", "--add", "branch.topic.description", "second"])
        _ = try await repo.run(["config", "--local", "branch.empty.description", ""])
        let config = root.appendingPathComponent(".git/config"), before = try Data(contentsOf: config)
        let values = try await repo.historyBranchDescriptions()
        XCTAssertEqual(values["refs/heads/topic"], "first\nline"); XCTAssertEqual(values["refs/heads/empty"], "")
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.historyBranchDescriptions(cancellation: token); XCTFail("Cancelled read ran") } catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf: config), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index").path))
    }
}
