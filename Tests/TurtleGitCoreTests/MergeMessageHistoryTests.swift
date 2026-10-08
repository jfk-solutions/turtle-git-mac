import XCTest
@testable import TurtleGitCore

final class MergeMessageHistoryTests: XCTestCase {
    func fixture(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "TurtleGit.MergeHistory.Tests." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        try body(prefs)
    }
    func testSourceLoadSaveLimitsAndConcurrentDialogs() throws {
        try fixture { prefs in
            prefs.set(2, forKey: "MaxHistoryItems")
            let first = MergeMessageHistory(defaults: prefs), second = MergeMessageHistory(defaults: prefs)
            first.add("one"); second.add("two"); first.add("three")
            XCTAssertEqual(prefs.stringArray(forKey: MergeMessageHistory.key), ["three", "two", "one"])
            XCTAssertEqual(second.entries, ["three", "two"])
            second.add("two"); XCTAssertEqual(first.entries, ["two", "three"])
            first.remove(["two"]); XCTAssertEqual(second.entries, ["three"])
            first.add(""); XCTAssertEqual(second.entries, ["three"])
        }
    }
    func testUTF16DeduplicationAndZeroLimitMatchSource() throws {
        try fixture { prefs in
            let history = MergeMessageHistory(defaults: prefs)
            history.add("é"); history.add("e\u{301}")
            XCTAssertEqual(history.entries.count, 2)
            XCTAssertEqual(Array(history.entries[0].utf16), [101, 769])
            let zero = MergeMessageHistory(defaults: prefs, limit: 0)
            XCTAssertEqual(zero.entries.count, 1)
            zero.add("new"); XCTAssertEqual(prefs.stringArray(forKey: MergeMessageHistory.key), ["new"])
            zero.remove(["new"]); XCTAssertEqual(history.entries, [])
        }
    }
    func testSavedDataClearsGlobalMergeAndRepositoryCommitHistoryOnly() throws {
        try fixture { prefs in
            let merge = MergeMessageHistory(defaults: prefs)
            let commit = CommitMessageHistory(repositoryIdentity: "repo", defaults: prefs)
            merge.add("merge"); commit.add("commit")
            prefs.set("draft", forKey: "Merge.MessageDraft"); prefs.set(25, forKey: "MaxHistoryItems")
            let store = SavedDataStore(preferences: prefs)
            XCTAssertEqual(store.summary(.messageHistory), .init(entries: 2, histories: 2))
            store.clear(.messageHistory)
            XCTAssertTrue(merge.entries.isEmpty); XCTAssertTrue(commit.entries.isEmpty)
            XCTAssertEqual(prefs.string(forKey: "Merge.MessageDraft"), "draft")
            XCTAssertEqual(prefs.integer(forKey: "MaxHistoryItems"), 25)
            merge.add("fresh"); XCTAssertEqual(merge.entries, ["fresh"])
        }
    }
}
