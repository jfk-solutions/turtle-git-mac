import XCTest
@testable import TurtleGitCore

final class CommitMessageHistoryTests: XCTestCase {
    func testExactCommitMessagesRemainIndependentAcrossDialogMutations() throws {
        let suite = "TurtleGit.ExactCommitHistory."+UUID().uuidString,defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let first = CommitMessageHistory(repositoryIdentity:"repo",defaults:defaults),second = CommitMessageHistory(repositoryIdentity:"repo",defaults:defaults)
        let a = "café\nbody",b = "cafe\u{301}\nbody"
        first.add(a);second.add(b)
        XCTAssertEqual(first.entries.count,2)
        XCTAssertTrue(first.entries[0].utf8.elementsEqual(b.utf8));XCTAssertTrue(first.entries[1].utf8.elementsEqual(a.utf8))
        first.add(a);XCTAssertEqual(first.entries.count,2)
        second.add("new message");first.removeExact([a])
        XCTAssertEqual(second.entries.count,2);XCTAssertTrue(second.entries[1].utf8.elementsEqual(b.utf8))
        first.add(a);second.removeExact([a,b]);XCTAssertEqual(first.entries,["new message"])
    }
    func testSharedProtocolExactMergeRemovalKeepsNewerMessages() throws {
        let suite = "TurtleGit.ExactMergeHistory."+UUID().uuidString,defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let first = MergeMessageHistory(defaults:defaults),second = MergeMessageHistory(defaults:defaults)
        let history:any MessageHistory = first,a = "é",b = "e\u{301}"
        first.add(a);first.add(b);second.add("new")
        history.removeExact([a]);XCTAssertEqual(second.entries.count,2)
        XCTAssertTrue(second.entries[1].utf8.elementsEqual(b.utf8))
        first.add(a);history.removeExact([a,b]);XCTAssertEqual(second.entries,["new"])
    }
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
