import XCTest
@testable import TurtleGitCore

final class CommitMessageHistoryTests: XCTestCase {
    func testPersistenceDeduplicationLimitAndIsolation() throws {
        let name = "TurtleGit.History.Tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let history = CommitMessageHistory(repositoryIdentity: "repo 雪", defaults: defaults, limit: 3)
        history.add(""); XCTAssertEqual(history.entries, [])
        for message in ["first\n\nbody", "second", "third", "fourth"] { history.add(message) }
        XCTAssertEqual(history.entries, ["fourth", "third", "second"])
        history.add("third"); XCTAssertEqual(history.entries, ["third", "fourth", "second"])
        let reopened = CommitMessageHistory(repositoryIdentity: "repo 雪", defaults: defaults, limit: 3)
        XCTAssertEqual(reopened.entries, history.entries)
        let other = CommitMessageHistory(repositoryIdentity: "other", defaults: defaults)
        other.add("separate"); XCTAssertEqual(history.entries, ["third", "fourth", "second"])
        history.remove(["third", "second"]); XCTAssertEqual(reopened.entries, ["fourth"])
    }
    func testInterleavedDialogMutationsReloadLatestStorage() throws {
        let name = "TurtleGit.History.Tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = CommitMessageHistory(repositoryIdentity: "same", defaults: defaults)
        let second = CommitMessageHistory(repositoryIdentity: "same", defaults: defaults)
        first.add("one"); second.add("two"); first.add("three")
        XCTAssertEqual(second.entries, ["three", "two", "one"])
        second.remove(["two"]); first.add("four")
        XCTAssertEqual(second.entries, ["four", "three", "one"])
        let disabled = CommitMessageHistory(repositoryIdentity: "disabled", defaults: defaults, limit: 0)
        disabled.add("ignored"); XCTAssertTrue(disabled.entries.isEmpty)
    }
}
