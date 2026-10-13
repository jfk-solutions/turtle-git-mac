import XCTest
@testable import TurtleGitCore

final class ReferenceLogOperationTests: XCTestCase {
    func testCapturedEventsRetainOrderDuplicatesAndRawSignaturesWithoutMutatingRepository() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["commit", "--allow-empty", "-m", "subject 雪\n\nbody: preserved"], environmentOverrides: ["GIT_AUTHOR_NAME": "Original 🦎", "GIT_AUTHOR_EMAIL": "original@example.invalid"])
        let second = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "--detach", "HEAD"]); _ = try await repo.run(["checkout", "main"])
        try Data("Canonical <canonical@example.invalid> Original 🦎 <original@example.invalid>\n".utf8).write(to: root.appendingPathComponent(".mailmap"))
        let rows = try await repo.referenceLog("HEAD")
        let selectedRows = Array(rows.prefix(3)) + [try XCTUnwrap(rows.first { $0.hash == first })]
        let ids = Set(selectedRows.map(\.id)), index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: root.appendingPathComponent(path))
        let entries = try await repo.referenceLogOperationEntries(snapshot: rows, selected: ids)
        XCTAssertEqual(entries.map(\.hash), rows.filter { ids.contains($0.id) }.map(\.hash))
        XCTAssertEqual(entries.filter { $0.hash == second }.count, 3)
        XCTAssertEqual(entries.first?.author, "Original 🦎"); XCTAssertEqual(entries.first?.email, "original@example.invalid")
        XCTAssertEqual(entries.first?.message, "subject 雪\n\nbody: preserved\n")
        XCTAssertEqual(entries.first?.parents, [first])
        let after = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(after, second); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
    }
    func testInvalidSelectionAndPreCancelledReadsFailBeforeDispatch() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = try await repo.referenceLog("HEAD")
        for ids in [Set<String>(), Set(["HEAD@{999}"])] {
            do { _ = try await repo.referenceLogOperationEntries(snapshot: rows, selected: ids); XCTFail("Invalid selection accepted") } catch {}
        }
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.referenceLogOperationEntries(snapshot: rows, selected: Set(rows.map(\.id)), cancellation: token); XCTFail("Cancelled read succeeded") }
        catch is OperationCancellationFailure {}
    }
}
